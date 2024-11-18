module GPTK
  # todo: ensure continuity between chapter fragments (might have to do using prompts)
  class Book
    @@start_time = Time.now
    attr_reader :chapters, :client, :last_output
    attr_accessor :parsers, :output_file

    def initialize(api_client,
                   outline,
                   instructions: '',
                   output_file: '',
                   rec_prompt: '',
                   parsers: CONFIG[:parsers],
                   mode: GPTK.mode)
      @client = api_client # Platform-agnostic API connection object (for now just supports OpenAI)
      # Reference document for book generation
      outline = ::File.exist?(outline) ? ::File.read(outline) : outline
      @outline = outline.encode 'UTF-8', invalid: :replace, undef: :replace, replace: '?'
      # Instructions for the AI agent
      instructions = ::File.exist?(instructions) ? ::File.read(instructions) : instructions
      @instructions = instructions.encode 'UTF-8', invalid: :replace, undef: :replace, replace: '?'
      @output_file = ::File.expand_path output_file
      @parsers = parsers
      @mode = mode
      @rec_prompt = ::File.exist?(rec_prompt) ? ::File.read(rec_prompt) : rec_prompt
      @genre = ''
      @chapters = [] # Book content
      @data = { # Data points to track while generating a book chapter by chapter
        prompt_tokens: 0,
        completion_tokens: 0,
        cached_tokens: 0,
        word_counts: [],
        current_chapter: 1
      }
    end

    # Construct the prompt passed to the AI agent
    def build_prompt(prompt, fragment_number)
      # meta_prompt = "Current chapter: #{chapter_number}.\n"
      generation_prompt = (fragment_number == 1) ? CONFIG[:initial_prompt] : CONFIG[:continue_prompt]
      [generation_prompt, prompt].join ' '
    end

    # Generate one complete chapter of the book using the given prompt
    def generate_chapter(general_prompt, chapter_number, thread, assistant_id=nil, fragments=nil, recommendations_prompt=nil)
      # puts "Generating chapter #{chapter_number}...\n"
      # chapter = ''

      messages = []

      (1..GPTK::Book::CONFIG[:chapter_fragments]).each do |i|
        prompt = build_prompt general_prompt, i
        @client.messages.create(
          thread_id: thread,
          parameters: { role: 'user', content: prompt }
        )

        # Create the run
        response = @client.runs.create(
          thread_id: thread,
          parameters: { assistant_id: assistant_id }
        )
        run_id = response['id']

        # Loop while awaiting status of the run
        while true do
          response = client.runs.retrieve id: run_id, thread_id: thread
          status = response['status']

          case status
          when 'queued', 'in_progress', 'cancelling'
            puts 'Processing...'
            sleep 1 # Wait one second and poll again
          when 'completed'
            messages = @client.messages.list thread_id: thread, parameters: { order: 'asc' }
            break # Exit loop and report result to user
          when 'requires_action'
            # Handle tool calls (see below)
          when 'cancelled', 'failed', 'expired'
            puts response['last_error'].inspect
            break
          else
            puts "Unknown status response: #{status}"
          end
        end

        puts messages['data'].last['content'].first['text']['value']
      end

      # @data[:current_chapter] += 1 # For data tracking purposes

      # # Revise chapter if 'recommendations_prompt' text or file are given
      # chapter = revise_chapter(chapter, recommendations_prompt) if recommendations_prompt

      # Count and tally the total number of words generated for each chapter
      # @data[:word_counts] << GPTK::Text.word_count(chapter)

      # chapter # Return the generated chapter
      messages
    end

    # Revise the chapter based upon a set of specific guidelines, using ChatGPT
    def revise_chapter(chapter, recommendations_prompt)
      puts "Revising chapter..."
      revision_prompt = "Please revise the following chapter content:\n\n" + chapter + "\n\nREVISIONS:\n" +
        recommendations_prompt + "\nDo NOT change the chapter title or number--this must remain the same as the original, and must accurately reflect the outline."
      GPTK::AI.query @client, revision_prompt, @data
    end

    # Parse an AI model response text into the chapter content and chapter summary
    # Note: due to the tendency of current AI models to produce hallucinations in output, significant
    # reformatting of the output is required to ensure consistency
    def parse_response(text, parsers=nil)
      # Split the response based on the chapter fragment and the summary (requires Unicode support!)
      parts = text.split(/\n{1,2}\p{Pd}{1,3}|\*{1,3}\s?\n{1,2}/u)
      fragment = if parts.size > 1
                   summary = parts[1].strip
                   parts[0].strip
                 else
                   text
                 end

      if parsers
        # Fix all the chapter titles (the default output suffers from multiple issues)
        parsers.each do |parser|
          case parsers[parser[0][1]].class # Pass each case to String#gsub!
          # Search expression, and replacement string
          when String then fragment.gsub! parsers[parser][1][0], parsers[parser][0][1]
          # Proc to run against the current fragment
          when Proc   then fragment.gsub! parsers[parser][1][0], parsers[parser][0][1]
          # Search expression to delete from output
          when nil    then fragment.gsub! parsers[parser][1], ''
          else puts "Parser: '#{parser[0][1]}' is invalid. Use a String, a Proc, or nil."
          end
        end
      end

      { chapter_fragment: fragment, chapter_summary: summary }
    end

    # Output useful information (metadata) after a run, (or part of a run) to STDOUT by default, or a file if given
    def output_run_info(file=nil)
      io_stream = case file.class
                    when File then file
                    when IO then ::File.open(file, 'a+')
                    when String then ::File.open(file, 'a+')
                    else STDOUT
                  end
      puts io_stream.class
      io_stream.seek 0, IO::SEEK_END
      io_stream.puts "\nSuccessfully generated #{CONFIG[:num_chapters]} chapters, for a total of #{@data[:word_counts].reduce &:+} words.\n"
      io_stream.puts <<~STRING

        Total token usage:

        - Prompt tokens used: #{@data[:prompt_tokens]}
        - Completion tokens used: #{@data[:completion_tokens]}
        - Total tokens used: #{@data[:prompt_tokens] + @data[:completion_tokens]}
        - Cached tokens used: #{@data[:cached_tokens]}
        - Cached token percentage: #{((@data[:cached_tokens].to_f / @data[:prompt_tokens]) * 100).round 2}%
      STRING
      io_stream.puts "\nElapsed time: #{((Time.now - @@start_time) / 60).round 1} minutes." # Print script run duration
      io_stream.puts "Words by chapter:\n"
      @data[:word_counts].each_with_index { |chapter_words, i| io_stream.puts "\nChapter #{i + 1}: #{chapter_words} words" }
    end

    # Write completed chapters to the output file
    # todo: add metadata to filename, such as date
    def save
      if @chapters.empty? || @chapters.nil?
        puts 'Error: no content to write.'
        return
      end
      output_file = ::File.open @output_file, 'w+'
      @chapters.each_with_index do |chapter, i|
        puts "Writing chapter #{i + 1} to file..."
        output_file.puts "#{chapter}\n"
      end
      puts "Successfully wrote #{@chapters.count} chapters to file: #{::File.path output_file}"
    end

    # Generate one or more chapters of the book
    def generate(number_of_chapters=CONFIG[:num_chapters], genre=@genre)
      @genre = genre if genre
      CONFIG[:num_chapters] = number_of_chapters
      # Run in mode 1 (Automation), 2 (Interactive), or 3 (Batch)
      case @mode
        when 1
          puts "Automation mode enabled: Generating a novel #{number_of_chapters} chapter(s) long.\n"
          puts 'Sending initial prompt, and GPT instructions...'

          # Create the Assistant if it does not exist already
          assistant_id = if @client.assistants.list['data'].empty?
            response = @client.assistants.create(
              parameters: {
                model: GPTK::AI::CONFIG[:openai_gpt_model],
                name: 'AI Book generator',
                description: nil,
                instructions: @instructions
              }
            )
            response['id']
                         else
                           @client.assistants.list['data'].first['id']
                         end

          # Create the Thread
          response = @client.threads.create
          thread_id = response['id']

          # Send the AI the book outline for future reference
          prompt = "The following text is the outline for a #{genre} novel I am about to generate. Use it as reference when processing future requests, and refer to it explicitly when generating each chapter of the book:\n\n#{@outline}"
          @client.messages.create(
            thread_id: thread_id,
            parameters: { role: 'user', content: prompt }
          )

          # Generate as many chapters as are specified
          prompt = "Generate a fragment of chapter 1 of the book, referring to the outline already supplied. Utilize as much output length as possible when returning content."
          messages = generate_chapter prompt, 1, thread_id, assistant_id

          # Cache result of last operation
          @last_output = messages

          # Output useful metadata
          # output_run_info
          # output_run_info @output_file
          @@start_time = Time.now

          response
        when 2
        when 3
        else puts 'Please input a valid script run mode.'
      end
    end
  end
end