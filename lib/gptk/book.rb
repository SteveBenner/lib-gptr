module GPTK
  # Book interface - responsible for managing and creating content in the form of a book with one or more chapters
  # TODO: add a feature which tracks how many repeated queries are run, and after a time will prompt users to REMOVE
  # a troublesome AI agent entirely from the Book object, so it won't be used, and assign a different agent its role
  class Book
    $chapters, $outline, $last_output = [], '', nil
    attr_reader :chapters, :chatgpt_client, :claude_client, :last_output, :agent
    attr_accessor :parsers, :output_file, :genre, :instructions, :outline

    def initialize(outline,
                   openai_client: nil,
                   anthropic_client: nil,
                   anthropic_api_key: nil,
                   xai_api_key: nil,
                   google_api_key: nil,
                   instructions: nil,
                   output_file: nil,
                   rec_prompt: nil,
                   genre: nil,
                   parsers: CONFIG[:parsers],
                   mode: GPTK.mode)
      unless openai_client || anthropic_client || xai_api_key || google_api_key
        puts 'Error: You must pass in at least ONE AI agent client or API key to the `new` method.'
        return
      end
      @chatgpt_client = openai_client
      @claude_client = anthropic_client
      @anthropic_api_key = anthropic_api_key
      @xai_api_key = xai_api_key
      @google_api_key = google_api_key
      # Reference document for book generation
      outline = ::File.exist?(outline) ? ::File.read(outline) : outline
      @outline = outline.encode 'UTF-8', invalid: :replace, undef: :replace, replace: '?'
      # Instructions for the AI agent
      instructions = (::File.exist?(instructions) ? ::File.read(instructions) : instructions) if instructions
      @instructions = instructions.encode('UTF-8', invalid: :replace, undef: :replace, replace: '?') if instructions
      @output_file = ::File.expand_path output_file if output_file
      @training = ::File.read ::File.expand_path(__FILE__, '../../prompts/trainer-murder-mystery.txt')
      @genre = genre
      @parsers = parsers
      @mode = mode.to_i
      @rec_prompt = (::File.exist?(rec_prompt) ? ::File.read(rec_prompt) : rec_prompt) if rec_prompt
      @chapters = [] # Book content
      @agent = if @chatgpt_client
                 'ChatGPT'
               elsif @claude_client
                 'Claude'
               elsif @xai_api_key
                 'Grok'
               elsif @google_api_key
                 'Gemini'
               end
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
      generation_prompt = (fragment_number == 1) ? CONFIG[:initial_prompt] : CONFIG[:continue_prompt]
      [generation_prompt, prompt].join ' '
    end

    # Parse an AI model response text into the chapter content and chapter summary
    # Note: due to the tendency of current AI models to produce hallucinations in output, significant
    # reformatting of the output is required to ensure consistency
    def parse_response(text, parsers = nil)
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
    def output_run_info(file = nil, start_time: nil)
      io_stream = case file.class
                  when File then file
                  when String then ::File.open(file, 'a+')
                  when IO then ::File.open(file, 'a+')
                  else STDOUT
                  end
      io_stream.seek 0, IO::SEEK_END
      io_stream.puts "\nSuccessfully generated #{CONFIG[:num_chapters]} chapters, for a total of #{@data[:word_counts].reduce(&:+)} words.\n\n"
      io_stream.puts <<~STRING
        Total token usage:
        - Prompt tokens used: #{@data[:prompt_tokens]}
        - Completion tokens used: #{@data[:completion_tokens]}
        - Total tokens used: #{@data[:prompt_tokens] + @data[:completion_tokens]}
        - Cached tokens used: #{@data[:cached_tokens]}
        - Cached token percentage: #{((@data[:cached_tokens].to_f / @data[:prompt_tokens]) * 100).round 2}%
      STRING
      io_stream.puts "\nElapsed time: #{GPTK.elapsed_time start_time} minutes.\n\n"
      io_stream.puts "Words by chapter:"
      @data[:word_counts].each_with_index { |chapter_words, i| io_stream.puts "\nChapter #{i + 1}: #{chapter_words} words" }
    end

    # Write completed chapters to the output file
    def save
      if @chapters.empty? || @chapters.nil?
        puts 'Error: no content to write.'
        return
      end
      filename = GPTK::File.fname_increment "#{@output_file}-#{@agent}#{@agent == 'Grok' ? '.md' : '.txt'}"
      output_file = ::File.open(filename, 'w+')
      @chapters.each_with_index do |chapter, i|
        puts "Writing chapter #{i + 1} to file..."
        output_file.puts chapter.join("\n\n") + "\n\n"
      end
      puts "Successfully wrote #{@chapters.count} chapters to file: #{::File.path output_file}"
    end

    # Generate one complete chapter of the book using the given prompt, and one AI (auto detects)
    def generate_chapter(general_prompt, thread_id: nil, assistant_id: nil, fragments: CONFIG[:chapter_fragments])
      messages = [] if @chatgpt_client
      chapter = []

      # Initialize claude memory every time we run a chapter generation operation
      if @claude_client
        # Ensure `claude_memory` is always an Array with ONE element using cache_control type: 'ephemeral'
        claude_memory = { role: 'user', content: [{ type: 'text', text: "FINAL OUTLINE:\n\n#{@outline}\n\nEND OF FINAL OUTLINE", cache_control: { type: 'ephemeral' } }] }
      end

      # Initialize manual memory for Grok via the input prompt
      if @xai_api_key
        general_prompt = "FINAL OUTLINE:\n\n#{@outline}\n\nEND OF FINAL OUTLINE\n\n#{general_prompt}"
      end

      # Manage Gemini memory
      if @google_api_key
        data = "OUTLINE:\n\n#{@outline}\n\nEND OF OUTLINE\n\nTRAINING DATA:\n\n#{@training}\n\nEND OF TRAINING DATA"
        cache_data = Base64.strict_encode64 data
        # Ensure min token amount is present in cache object, otherwise it will throw an API error
        chars_to_add = GPTK::AI::CONFIG[:gemini_min_cache_tokens] * 7 - cache_data.size
        if chars_to_add > 0
          cache_data = Base64.strict_encode64 "#{'F' * chars_to_add}\n\n#{cache_data}"
        end
        request_payload = {
          model: 'models/gemini-1.5-flash-001',
          contents: [{
              role: 'user',
              parts: [{ inline_data: { mime_type: 'text/plain', data: cache_data } }]
            }],
          ttl: CONFIG[:gemini_ttl]
        }
        request_payload.update({ systemInstruction: { parts: [{ text: @instructions }] } }) if @instructions

        # Cache the content
        begin
          cache_response = HTTParty.post(
            "https://generativelanguage.googleapis.com/v1beta/cachedContents?key=#{@google_api_key}",
            headers: { 'Content-Type' => 'application/json' },
            body: request_payload.to_json
          )
          cache_response_body = JSON.parse cache_response.body
        rescue => e
          puts "Error: #{e.class}: '#{e.message}'. Retrying query..."
          sleep 10
          cache_response = HTTParty.post(
            "https://generativelanguage.googleapis.com/v1beta/cachedContents?key=#{@google_api_key}",
            headers: { 'Content-Type' => 'application/json' },
            body: request_payload.to_json
          )
          cache_response_body = JSON.parse cache_response.body
        end
        cache_name = cache_response_body['name']

        # Set up the payload
        payload = {
          contents: [{ role: 'user', parts: [{ text: general_prompt }] }],
          cachedContent: cache_name
        }
      end

      (1..fragments).each do |i|
        prompt = build_prompt general_prompt, i
        puts "Generating fragment #{i} using #{@agent}..."

        if @chatgpt_client # Using the Assistant API
          @chatgpt_client.messages.create(
            thread_id: thread_id,
            parameters: { role: 'user', content: prompt }
          )

          # Create the run
          response = @chatgpt_client.runs.create(
            thread_id: thread_id,
            parameters: { assistant_id: assistant_id }
          )
          run_id = response['id']

          # Loop while awaiting status of the run
          while true do
            response = @chatgpt_client.runs.retrieve id: run_id, thread_id: thread_id
            status = response['status']

            case status
            when 'queued', 'in_progress', 'cancelling'
              puts 'Processing...'
              sleep 1 # Wait one second and poll again
            when 'completed'
              messages = @chatgpt_client.messages.list thread_id: thread_id, parameters: { order: 'desc' }
              break # Exit loop and report result to user
            when 'requires_action'
              # Handle tool calls (see below)
            when 'cancelled', 'failed', 'expired'
              puts 'Error!'
              puts response['last_error'].inspect
              break
            else
              puts "Unknown status response: #{status}"
            end
          end
          chapter << "#{messages['data'].first['content'].first['text']['value']}\n\n"
        end

        if @claude_client
          claude_messages = [claude_memory, { role: 'user', content: prompt }]
          claude_fragment = "#{GPTK::AI::Claude.query_with_memory @anthropic_api_key, claude_messages}\n\n"
          claude_memory[:content].first[:text] << "\n\nFRAGMENT #{i}:\n#{claude_fragment}"
          chapter << claude_fragment
        end

        if @xai_api_key
          grok_prompt = "#{prompt}\n\nGenerate as much output as you can!"
          grok_fragment = "#{GPTK::AI::Grok.query(@xai_api_key, grok_prompt)}\n\n"
          chapter << grok_fragment
          general_prompt << "\n\nFRAGMENT #{i}:\n\n#{grok_fragment}"
        end

        if @google_api_key
          gemini_fragment = "#{GPTK::AI::Gemini.query_with_cache(@google_api_key, payload)}\n\n"
          chapter << gemini_fragment
          # Set up the cache with the latest generated chapter fragment added
          cache_data = Base64.strict_encode64 "\n\nFRAGMENT #{i}:\n\n#{gemini_fragment}#{cache_data}"
          request_payload = {
            model: 'models/gemini-1.5-flash-001',
            contents: [{
                         role: 'user',
                         parts: [{ inline_data: { mime_type: 'text/plain', data: cache_data } }]
                       }],
            ttl: CONFIG[:gemini_ttl]
          }

          # Remove old cache
          HTTParty.post(
            "https://generativelanguage.googleapis.com/v1beta/#{cache_name}?key=#{@google_api_key}"
          )

          # Create new, updated cache
          begin
            cache_response = HTTParty.post(
              "https://generativelanguage.googleapis.com/v1beta/cachedContents?key=#{@google_api_key}",
              headers: { 'Content-Type' => 'application/json' },
              body: request_payload.to_json
            )
            cache_response_body = JSON.parse cache_response.body
          rescue => e
            puts "Error: #{e.class}: '#{e.message}' Retrying query..."
            sleep 10
            cache_response = HTTParty.post(
              "https://generativelanguage.googleapis.com/v1beta/cachedContents?key=#{@google_api_key}",
              headers: { 'Content-Type' => 'application/json' },
              body: request_payload.to_json
            )
            cache_response_body = JSON.parse cache_response.body
          end
          cache_name = cache_response_body['name']

          # Set up the payload again
          payload = {
            contents: [{ role: 'user', parts: [{ text: general_prompt }] }],
            cachedContent: cache_name
          }
        end
      end

      if @google_api_key
        # Remove old cache
        HTTParty.post(
          "https://generativelanguage.googleapis.com/v1beta/#{cache_name}?key=#{@google_api_key}"
        )
      end

      @data[:word_counts] << GPTK::Text.word_count(chapter.join "\n")
      @chapters << chapter
      chapter
    end

    # Generate one complete chapter of the book using the back-and-forth 'zipper' technique
    def generate_chapter_zipper(parity, chapter_num, thread_id, assistant_id, fragments = GPTK::Book::CONFIG[:chapter_fragments], prev_chapter = [], anthropic_api_key: nil)
      # Initialize claude memory every time we run a chapter generation operation
      # Ensure `claude_memory` is always an Array with ONE element using cache_control type: 'ephemeral'
      claude_memory = { role: 'user', content: [{ type: 'text', text: "FINAL OUTLINE:\n\n#{@outline}\n\nEND OF FINAL OUTLINE", cache_control: { type: 'ephemeral' } }] }

      unless prev_chapter.empty? # Add any previously generated chapter to the memory of the proper AI
        if parity.zero? # ChatGPT
          CHATGPT.messages.create thread_id: thread_id, parameters: { role: 'user', content: "PREVIOUS CHAPTER:\n\n#{prev_chapter.join("\n\n")}" }
        else # Claude
          claude_memory[:content].first[:text] << "\n\nPREVIOUS CHAPTER:\n\n#{prev_chapter.join("\n\n")}"
        end
      end

      # Generate the chapter fragment by fragment
      meta_prompt = GPTK::Book::CONFIG[:meta_prompt]
      chapter = []
      (1..fragments).each do |j|
        # Come up with an initial version of the chapter, based on the outline and prior chapter
        chapter_gen_prompt = case j
                             when 1 then "Referencing the final outline, write the first part of chapter #{chapter_num} of the #{@genre} story. #{meta_prompt}"
                             when fragments then "Referencing the final outline and the current chapter fragments, write the final conclusion of chapter #{chapter_num} of the #{@genre} story. #{meta_prompt}"
                             else "Referencing the final outline and the current chapter fragments, continue writing chapter #{chapter_num} of the #{@genre} story. #{meta_prompt}"
                             end
        chapter << if parity.zero? # ChatGPT
                     parity = 1
                     fragment_text = GPTK::AI::ChatGPT.run_assistant_thread @chatgpt_client, thread_id, assistant_id, chapter_gen_prompt
                     claude_memory[:content].first[:text] << "\n\nCHAPTER #{chapter_num}, FRAGMENT #{j}:\n\n#{fragment_text}"
                     fragment_text
                   else # Claude
                     parity = 0
                     prompt_messages = [claude_memory, { role: 'user', content: chapter_gen_prompt }]
                     fragment_text = GPTK::AI::Claude.query_with_memory anthropic_api_key, prompt_messages
                     claude_memory[:content].first[:text] << "\n\nCHAPTER #{chapter_num}, FRAGMENT #{j}:\n\n#{fragment_text}"
                     CHATGPT.messages.create thread_id: thread_id, parameters: { role: 'user', content: fragment_text }
                     fragment_text
                   end
      end
      @chapters << chapter
      chapter # Array of Strings representing chapter fragments for one chapter
    end

    # Generate one or more chapters of the book, using a single AI (auto detects)
    def generate(number_of_chapters = CONFIG[:num_chapters], fragments = CONFIG[:chapter_fragments])
      start_time = Time.now
      CONFIG[:num_chapters] = number_of_chapters
      book = []
      begin
        # Run in mode 1 (Automation), 2 (Interactive), or 3 (Batch)
        case @mode
        when 1
          puts "Automation mode enabled: Generating a novel #{number_of_chapters} chapter(s) long." +
                 (fragments ? " #{fragments} fragments per chapter." : '')
          puts 'Sending initial prompt, and GPT instructions...'

          if @chatgpt_client
            # Create the Assistant if it does not exist already
            assistant_id = if @chatgpt_client.assistants.list['data'].empty?
                            response = @chatgpt_client.assistants.create(
                               parameters: {
                                 model: GPTK::AI::CONFIG[:openai_gpt_model],
                                 name: 'AI Book generator',
                                 description: nil,
                                 instructions: @instructions
                               }
                             )
                             response['id']
                           else
                             @chatgpt_client.assistants.list['data'].first['id']
                           end

            # Create the Thread
            response = @chatgpt_client.threads.create
            thread_id = response['id']

            # Send the AI the book outline for future reference
            prompt = "The following text is the outline for a #{genre} novel I am about to generate. Use it as reference when processing future requests, and refer to it explicitly when generating each chapter of the book:\n\n#{@outline}"
            @chatgpt_client.messages.create(
              thread_id: thread_id,
              parameters: { role: 'user', content: prompt }
            )
          end

          if @claude_client
            claude_memory = [] # TODO: complete this
          end

          # Generate as many chapters as are specified
          (1..number_of_chapters).each do |i|
            puts "Generating chapter #{i}..."
            prompt = "Generate a fragment of chapter #{i} of the book, referring to the outline already supplied. Utilize as much output length as possible when returning content. Output ONLY raw text, no JSON or HTML."
            book << generate_chapter(prompt, thread_id: thread_id, assistant_id: assistant_id, fragments: fragments)
          end

          # Cache result of last operation
          @last_output = book

          book
        when 2 # TODO
        when 3 # TODO
        else puts 'Please input a valid script run mode.'
        end
      ensure
        @chatgpt_client.threads.delete id: thread_id if @chatgpt_client # Garbage collection
        # Output some metadata - useful information about the run, API status, book content, etc.
        output_run_info start_time: start_time
        $chapters = book if $chapters
        $outline = @outline if $outline
        $last_output = @last_output if $last_output
        puts "Claude memory word count: #{GPTK::Text.word_count claude_memory[:content].first[:text]}" if claude_memory
      end
    end

    # Generate one or more chapters of the book using the back-and-forth 'zipper' technique
    def generate_zipper(number_of_chapters = CONFIG[:num_chapters], fragments = 1)
      start_time = Time.now
      CONFIG[:num_chapters] = number_of_chapters # Update config
      chapters = []
      begin
        puts "Automation mode enabled: Generating a novel #{number_of_chapters} chapter(s) long.\n"
        puts 'Sending initial prompt, and GPT instructions...'

        prompt = "The following text is the outline for a #{@genre} novel I am about to generate. Use it as reference when processing future requests, and refer to it explicitly when generating each chapter of the book:\n\nFINAL OUTLINE:\n\n#{@outline}\n\nEND OF FINAL OUTLINE"

        if @chatgpt_client
          # Create the Assistant if it does not exist already
          assistant_id = if @chatgpt_client.assistants.list['data'].empty?
                           response = @chatgpt_client.assistants.create(
                             parameters: {
                               model: GPTK::AI::CONFIG[:openai_gpt_model],
                               name: 'AI Book generator',
                               description: nil,
                               instructions: @instructions
                             }
                           )
                           response['id']
                         else
                           @chatgpt_client.assistants.list['data'].last['id']
                         end

          # Create the Thread
          thread_id = @chatgpt_client.threads.create['id']

          # Send ChatGPT the book outline for future reference
          @chatgpt_client.messages.create(
            thread_id: thread_id,
            parameters: { role: 'user', content: prompt }
          )
        end

        claude_memory = {}
        if @claude_client
          # Instantiate Claude memory for chapter production conversation
          # Ensure `claude_messages` is always an Array with ONE element using cache_control type: 'ephemeral'
          initial_memory = "#{prompt}\n\nINSTRUCTIONS FOR CLAUDE:\n\n#{@instructions}END OF INSTRUCTIONS"
          claude_memory = { role: 'user', content: [{ type: 'text', text: initial_memory, cache_control: { type: 'ephemeral' } }] }
        end

        # Generate as many chapters as are specified
        parity = 0
        prev_chapter = []
        (1..number_of_chapters).each do |chapter_number| # CAREFUL WITH THIS VALUE!
          chapter = generate_chapter_zipper(parity, chapter_number, thread_id, assistant_id, fragments, prev_chapter)
          parity = parity.zero? ? 1 : 0
          prev_chapter = chapter
          @last_output = chapter # Cache results of the last operation
          chapters << chapter
        end

        @last_output = chapters # Cache results of the last operation
        chapters # Return the generated story chapters
      ensure
        @chatgpt_client.threads.delete id: thread_id # Garbage collection
        # Output some metadata - useful information about the run, API status, book content, etc.
        output_run_info start_time: start_time
        $chapters = chapters if $chapters
        $outline = @outline if $outline
        $last_output = @last_output if $last_output
        puts "Claude memory word count: #{GPTK::Text.word_count claude_memory[:content].first[:text]}" if claude_memory
      end
      puts "Congratulations! Successfully generated #{chapters.count} chapters."
      @book = chapters
      chapters
    end

    # Revise the chapter based upon a set of specific guidelines, using ChatGPT
    def revise_chapter(chapter, recommendations_prompt)
      puts "Revising chapter..."
      revision_prompt = "Please revise the following chapter content:\n\n" + chapter + "\n\nREVISIONS:\n" +
        recommendations_prompt + "\nDo NOT change the chapter title or number--this must remain the same as the original, and must accurately reflect the outline."
      GPTK::AI.query @chatgpt_client, revision_prompt, @data
    end

    # Revises a chapter fragment-by-fragment, ensuring adherence to specific content rules.
    #
    # This method processes a given chapter, analyzing and revising its content
    # using AI clients such as ChatGPT and Claude. The revisions focus on reducing
    # the frequency of predefined "bad patterns" and adhering to specific content rules.
    # The revised chapter is returned as an array of updated fragments.
    #
    # @param [Array<String>] chapter
    #   An array of chapter fragments to be revised. Each fragment is a string
    #   representing a portion of the chapter.
    #
    # @param [Object] chatgpt_client (optional)
    #   The ChatGPT client instance to use for querying and revisions.
    #   Defaults to `@chatgpt_client` if not explicitly provided.
    #
    # @param [Object] claude_client (optional)
    #   The Claude client instance for querying and memory management.
    #   Defaults to `@claude_client` if not explicitly provided.
    #
    # @param [String, nil] anthropic_api_key (optional)
    #   An API key for authenticating requests to the Claude client.
    #   Defaults to `nil` if not explicitly provided.
    #
    # @return [Array<String>]
    #   The final revised chapter, in two formats: plain text, and numbered (by sentence)
    #
    # @example Revise a chapter with ChatGPT and Claude clients
    #   chapter = [
    #     "The protagonist's heart raced as they entered the eerie cave.",
    #     "The air grew thick with tension, and a lion roared in the distance."
    #   ]
    #   revised = revise_chapter1(chapter, chatgpt_client: my_chatgpt_client, claude_client: my_claude_client)
    #   puts revised
    #
    # @note
    #   - The method ensures only one instance of any "bad pattern" appears across the entire chapter.
    #   - When both clients are provided, the method coordinates their responses, with Claude
    #     adding contextual revisions to ChatGPT's output.
    #   - The method handles API interactions, memory updates, and garbage collection for AI threads.
    #   - Currently it is NOT thorough, and this is a limitation of the AIs themselves unfortunately.
    #
    # TODO: write 'revise_book' that can take an entire book file and break it down chapter by chapter
    def revise_chapter1(chapter, chatgpt_client: @chatgpt_client, anthropic_api_key: nil, xai_api_key: nil, google_api_key: nil)
      # TODO: add Gemini code
      start_time = Time.now
      claude_memory = nil
      chapter_text = chapter.instance_of?(String) ? chapter : chapter.join(' ')

      begin
        # Give every sentence of the chapter a number, for parsing out bad patterns
        sentences = chapter_text.split /(?<!\.\.\.)(?<!O\.B\.F\.)(?<=\.|!|\?)/ # TODO: fix regex
        numbered_chapter = sentences.map.with_index { |sentence, i| "**[#{i + 1}]** #{sentence.strip}" }.join(' ')

        # Iterate through all 'bad patterns' and offer the user choice in how to address each one
        chatgpt_matches = []
        claude_matches = []
        grok_matches = []
        gemini_matches = []
        CONFIG[:bad_patterns].each do |pattern, prompt|
          # Scan for bad patterns and generate an Array of results to later parse out of the book content or rewrite
          bad_pattern_prompt = <<~STR
            Analyze the given chapter text exhaustively for the pattern: (#{pattern}), and output all found matches as a JSON object. #{prompt}
  
            ONLY output the object, no other response text or conversation, and do NOT put it in a Markdown block. ONLY output proper JSON. Create the following output: an Array of objects which each include: 'match' (the recognized pattern), 'sentence' (the surrounding sentence the pattern was found in) and 'sentence_count' (the number of the sentence the bad pattern was found in). BE EXHAUSTIVE--once you find ONE pattern, do a search for all other matching cases and add those to the output. Restrict output to #{CONFIG[:max_total_matches]} matches total, but keep scanning for matches until you reach as close as you can to that number..\n\nCHAPTER:\n\n#{numbered_chapter}
          STR

          # TODO: rewrite the duplicate deletion code to account for all 4 AIs...

          print 'ChatGPT is analyzing the text for bad patterns...'
          begin # Retry the query if we get a bad JSON response
            chatgpt_matches = JSON.parse(GPTK::AI::ChatGPT.query(@chatgpt_client, @data, bad_pattern_prompt))['matches']
          rescue JSON::ParserError => e
            puts "Error: #{e.class}. Retrying query..."
            sleep 10
            chatgpt_matches = JSON.parse(GPTK::AI::ChatGPT.query(@chatgpt_client, @data, bad_pattern_prompt))['matches']
          end
          puts " #{chatgpt_matches.count} bad pattern matches detected!"

          print 'Grok is analyzing the text for bad patterns...'
          grok_matches = GPTK::AI::Grok.query xai_api_key, bad_pattern_prompt
          grok_matches = JSON.parse(grok_matches.gsub /(```json\n)|(\n```)/, '')
          puts " #{grok_matches.count} bad pattern matches detected!"

          print 'Claude is analyzing the text for bad patterns...'
          claude_matches = JSON.parse GPTK::AI::Claude.query_with_memory(
            anthropic_api_key, [{ role: 'user', content: bad_pattern_prompt }]
          )
          unless claude_matches.instance_of? Array
            claude_matches = if claude_matches.key? 'matches'
                               claude_matches['matches']
                             elsif claude_matches.key? 'patterns'
                               claude_matches['patterns']
                             end
          end
          puts " #{claude_matches.count} bad pattern matches detected!"

          # Remove any duplicate matches from Claude's results (matches already picked up by ChatGPT or Grok)
          puts 'Deleting any duplicate matches found...'
          claude_matches.delete_if do |match|
            chatgpt_matches.any? { |i| i['match'] == match['match'] && i['sentence_count'] == match['sentence_count'] }
          end
          claude_matches.delete_if do |match|
            chatgpt_matches.any? do |i|
              i['sentence'] == match['sentence'] && i['sentence_count'] == match['sentence_count']
            end
          end
          claude_matches.delete_if do |match|
            grok_matches.any? { |i| i['match'] == match['match'] && i['sentence_count'] == match['sentence_count'] }
          end
          claude_matches.delete_if do |match|
            grok_matches.any? { |i| i['sentence'] == match['sentence'] && i['sentence_count'] == match['sentence_count'] }
          end

          # Remove any duplicates from ChatGPT's results (matches already picked up by Claude or Grok)
          chatgpt_matches.delete_if do |match|
            claude_matches.any? { |i| i['match'] == match['match'] && i['sentence_count'] == match['sentence_count'] }
          end
          chatgpt_matches.delete_if do |match|
            claude_matches.any? do |i|
              i['sentence'] == match['sentence'] && i['sentence_count'] == match['sentence_count']
            end
          end
          chatgpt_matches.delete_if do |match|
            grok_matches.any? { |i| i['match'] == match['match'] && i['sentence_count'] == match['sentence_count'] }
          end
          chatgpt_matches.delete_if do |match|
            grok_matches.any? { |i| i['sentence'] == match['sentence'] && i['sentence_count'] == match['sentence_count'] }
          end
        end

        # Merge the results of each AI's analysis
        bad_patterns = chatgpt_matches.uniq.concat(claude_matches.uniq).concat(grok_matches.uniq)
        # Group the results by match
        bad_patterns = bad_patterns.map { |p| Utils.symbolify_keys p }.group_by { |i| i[:match] }
        # Sort the matches by the order of when they appear in the chapter
        bad_patterns.each do |pattern, matches|
          bad_patterns[pattern] = matches.sort_by { |m| m[:word] }
        end

        # Create a new ChatGPT Thread
        thread_id = chatgpt_client.threads.create['id'] if @chatgpt_client

        match_count = bad_patterns.values.flatten.count
        puts "#{bad_patterns.count} bad patterns detected (#{match_count} total matches):"
        bad_patterns.each do |pattern, matches|
          puts "- '#{pattern}' (#{matches.count} counts)"
        end

        # Prompt user for the mode
        puts 'How would you like to proceed with the revision process for the detected bad patterns?'
        puts 'Enter an option number: 1, or 2:'
        puts 'Mode 1: Apply an operation to ALL instances of bad pattern matches at once.'
        puts 'Mode 2: Iterate through each bad pattern and choose an operation to apply to all of the matches.'
        mode = gets.to_i

        revised_chapter = chapter_text
        case mode
        when 1 # Apply operation to ALL matches
          bad_matches = bad_patterns # Flatten the grouped matches into a single list and order them
                          .flatten.flatten.delete_if { |p| p.instance_of? String }.sort_by { |p| p[:sentence_count] }
          puts "Which operation do you wish to apply to all #{bad_matches.count}? 1) Keep as is, 2) Change, 3) Delete"
          operation = gets.to_i

          case operation
          when 1 then puts 'Content accepted as-is.'
          when 2 # Have Claude or ChatGPT revise each sentence containing a bad pattern match
            puts 'Would you like to 1) replace each match occurrence manually, or 2) use Claude to replace it?'
            choice = gets.to_i

            case choice
            when 1
              bad_matches.each do |match|
                puts "Pattern: #{match[:match]}"
                puts "Sentence: #{match[:sentence]}"
                puts "Sentence Number: #{match[:sentence_count]}"
                puts 'Please input your revised sentence.'
                revised_sentence = gets
                revised_chapter.gsub! match[:sentence], revised_sentence
                puts 'Revision complete!'
              end
            when 2
              bad_matches.each do |match|
                prompt = <<~STR
                  Revise the following sentence in order to eliminate the bad pattern, making sure completely rewrite the sentence. PATTERN: '#{match[:match]}'. SENTENCE: '#{match[:sentence]}'. ONLY output the revised sentence, no other commentary or discussion.
                STR
                # chatgpt_revised_sentence = GPTK::AI::ChatGPT.query @chatgpt_client, @data, prompt
                claude_revised_sentence = GPTK::AI::Claude.query_with_memory anthropic_api_key,
                                                                             [{ role: 'user', content: prompt }]
                # Revise the chapter text based on AI feedback
                puts "Revising sentence #{match[:sentence_count]} using Claude..."
                puts "Original: #{match[:sentence]}"
                puts "Revision: #{claude_revised_sentence}"
                sleep 1
                revised_chapter.gsub! match[:sentence], claude_revised_sentence
              end
            else raise 'Error: Input either 1 or 2'
            end

            puts "Successfully enacted #{bad_matches.count} revisions!"
          when 3 # Delete all examples of bad pattern sentences
            bad_matches.each do |match|
              puts 'Revising chapter...'
              puts "Sentence [#{match[:sentence_count]}] deleted: #{match[:sentence]}"
              sleep 1
              revised_chapter.gsub! match[:sentence], ''
            end
          else raise 'Invalid operation. Must be 1, 2, or 3'
          end
        when 2 # Iterate through bad patterns and prompt user for action to perform on all matches per pattern
          bad_patterns.each do |pattern, matches|
            sentence_positions = matches.sort_by { |m| m[:sentence_count] }.collect { |m| m[:sentence_count] }.join ', '
            puts "\nBad pattern detected: '#{pattern}' #{matches.count} matches found (sentences #{sentence_positions})"
            puts "Which operation do you wish to apply to all #{matches.count} matches?"
            puts '1) Keep as is, 2) Change, 3) Delete, or 4) Review'
            operation = gets.to_i

            case operation
            when 1
              puts "Ignoring #{matches.count} matches for pattern '#{pattern}'..."
            when 2
              puts 'Would you like to 1) have ChatGPT perform revisions on all the matches using its own judgement,'
              puts 'or 2) would you like to provide a general prompt ChatGPT will use to revise the matches?'
              choice = gets.to_i
              case choice
              when 1 # Have ChatGPT auto-revise content
                matches.each do |match|
                  prompt = <<~STR
                    Revise the following sentence in order to eliminate the bad pattern, making sure completely rewrite the sentence. PATTERN: '#{pattern}'. SENTENCE: '#{match[:sentence]}'. ONLY output the revised sentence, no other commentary or discussion.
                  STR
                  puts "Revising sentence #{match[:sentence_count]}..."
                  chatgpt_revised_sentence = GPTK::AI::ChatGPT.query @chatgpt_client, @data, prompt
                  puts "ChatGPT revision: '#{chatgpt_revised_sentence}'"
                  revised_chapter.gsub! match[:sentence], chatgpt_revised_sentence
                end
                puts "Successfully revised #{matches.count} bad pattern occurrences using ChatGPT!"
              when 2 # Prompt user to specify prompt for the ChatGPT
                puts 'Please enter a prompt to instruct ChatGPT regarding the revision of these bad pattern matches.'
                user_prompt = gets
                matches.each do |match|
                  prompt = <<~STR
                    Revise the following sentence in order to eliminate the bad pattern, making sure completely rewrite the sentence. PATTERN: '#{pattern}'. SENTENCE: '#{match[:sentence]}'. ONLY output the revised sentence, no other commentary or discussion. #{user_prompt}
                  STR
                  puts "Revising sentence #{match[:sentence_count]}..."
                  chatgpt_revised_sentence = GPTK::AI::ChatGPT.query @chatgpt_client, @data, "#{prompt}"
                  puts "ChatGPT revision: '#{chatgpt_revised_sentence}'"
                  revised_chapter.gsub! match[:sentence], chatgpt_revised_sentence
                end
                puts "Successfully revised #{matches.count} bad pattern occurrences using your prompt and ChatGPT!"
              else raise 'Invalid option. Must be 1 or 2'
              end
            when 3 # Delete all instances of the bad pattern
              matches.each do |match|
                puts "Deleting sentence #{match[:sentence_count]}..."
                revised_chapter.gsub! match[:sentence], ''
                puts "Deleted: '#{match[:sentence]}'"
              end
              puts "Deleted #{matches.count} bad pattern occurrences!"
            when 4 # Interactively or automagically address each bad pattern match one by one
              puts "Reviewing #{matches.count} matches of pattern: '#{pattern}'..."
              matches.each do |match|
                puts "Pattern: #{match[:match]}"
                puts "Sentence: #{match[:sentence]}"
                puts "Sentence Number: #{match[:sentence_count]}"
                puts 'Would you like to 1) Keep as is, 2) Revise, or 3) Delete?'
                choice = gets.to_i
                case choice
                when 1 then puts 'Original content left unaltered.'
                when 2
                  puts 'Would you like to 1) input a revision yourself, or 2) use ChatGPT to generate a revision?'
                  choice2 = gets.to_i
                  if choice2 == 1
                    puts 'Please input your revised sentence:'
                    user_revision = gets
                    revised_chapter.gsub! match[:sentence], user_revision
                  elsif choice2 == 2
                    puts 'Generating a revision using ChatGPT...'
                    prompt = <<~STR
                      Revise the following sentence in order to eliminate the bad pattern, making sure completely rewrite the sentence. PATTERN: '#{match[:match]}'. SENTENCE: '#{match[:sentence]}'. ONLY output the revised sentence, no other commentary or discussion.
                    STR
                    chatgpt_revision = GPTK::AI::ChatGPT.query @chatgpt_client, @data, prompt
                    puts "Original sentence: #{match[:sentence]}"
                    puts "Revised sentence: #{chatgpt_revision}"
                    puts 'Would you like to 1) Accept this revised sentence, 2) Revise it again, or 3) Keep original?'
                    choice = gets.to_i
                    case choice
                    when 1
                      puts 'Updating chapter...'
                      revised_chapter.gsub! match[:sentence], chatgpt_revision
                    when 2
                      puts 'Generating a new revision...'
                      chatgpt_revision = GPTK::AI::ChatGPT.query @chatgpt_client, @data, prompt
                      puts "Revised sentence: #{chatgpt_revision}"
                      puts 'How do you like this revision? Indicate whether you accept or want another rewrite.'
                      puts 'Input Y|y or N|n to indicate yes or no to accepting this revision.'
                      response = gets.chomp
                      until response == 'Y' || response == 'y' do
                        puts 'Generating a new revision...'
                        chatgpt_revision = GPTK::AI::ChatGPT.query @chatgpt_client, @data, prompt
                        puts "New revised sentence: #{chatgpt_revision}"
                        puts 'How do you like this new revision? Indicate whether you accept or want another rewrite.'
                        response = gets.chomp
                      end
                      revised_chapter.gsub! match[:sentence], chatgpt_revision
                    when 3
                      puts "Leaving sentence #{match[:sentence_count]} unaltered: '#{match[:sentence]}'..."
                    else raise 'Invalid choice. Must be 1, 2, or 3'
                    end
                  else
                    raise 'Invalid choice. Must be 1 or 2'
                  end
                when 3
                  print "Removing sentence #{match[:sentence_count]}: '#{match[:sentence]}'..."
                  revised_chapter.gsub! match[:sentence], ''
                  puts ' Done!'
                else raise 'Invalid choice. Must be 1, 2, or 3'
                end
              end
            else raise 'Invalid operation. Must be 1, 2, 3, or 4'
            end
          end
        else raise 'Invalid mode. Must be 1, or 2'
        end

        # Give every sentence of the revised chapter a number, for proofreading and correcting errors later
        revised = revised_chapter.split /(?<=\.)|(?<=\!)|(?<=\?)/
        numbered_chapter = revised.map.with_index { |sentence, i| "**[#{i + 1}]** #{sentence.strip}" }.join(' ')
      ensure
        @chatgpt_client.threads.delete id: thread_id if @chatgpt_client # Garbage collection
        @last_output = revised_chapter
        puts "\nElapsed time: #{GPTK.elapsed_time start_time} minutes"
        if claude_memory
          puts "Claude memory word count: #{GPTK::Text.word_count claude_memory[:content].first[:text]}"
        end
      end

      [revised_chapter, numbered_chapter]
    end

    # This is an alternate chapter revision method for REMOVING DUPLICATE CONTENT ONLY
    def revise_chapter2(chapter, chatgpt_client: nil, anthropic_api_key: nil, xai_api_key: nil, google_api_key: nil)
      agent = if chatgpt_client
                 'ChatGPT'
               elsif anthropic_api_key
                 'Claude'
               elsif xai_api_key
                 'Grok'
               elsif google_api_key
                 'Gemini'
               end
      start_time = Time.now
      claude_memory = nil
      chapter_text = chapter.instance_of?(String) ? chapter : chapter.join(' ')

      begin
        # Give every sentence of the chapter a number, for parsing out repeated content
        sentences = chapter_text.split /(?<!\.\.\.)(?<!O\.B\.F\.)(?<=\.|!|\?)/ # TODO: fix regex
        numbered_chapter = sentences.map.with_index { |sentence, i| "**[#{i + 1}]** #{sentence.strip}" }.join(' ')

        # Scan the chapter for instances of repeated content and offer the user choice in how to address them
        chatgpt_matches = []
        claude_matches = []
        grok_matches = []
        gemini_matches = []
        # Scan for repeated content and generate an Array of results to later parse out of the book or rewrite
        repetitions_prompt = <<~STR
          Analyze the given chapter text for instances of repeated/duplicated content, and output all found matches as a JSON object.

          ONLY output the object, no other response text or conversation, and do NOT put it in a Markdown block. ONLY output valid JSON. Create the following output: an Array of objects which each include: 'match' (the recognized repeated content), 'sentence' (the surrounding sentence the pattern was found in), and 'sentence_count' (the number of the sentence surrounding the repeated content). ONLY include one instance of integer results in 'sentence_count'; repeat matches if necessary. BE EXHAUSTIVE. Matches must be AT LEAST two words long.\n\nCHAPTER:\n\n#{numbered_chapter}
        STR

        if google_api_key
          print 'Gemini is analyzing the text for repeated content...'
          begin
            gemini_matches = JSON.parse GPTK::AI::Gemini.query(google_api_key, repetitions_prompt)
          rescue
            puts 'Error: Gemini API returned a bad response. Retrying query...'
            until gemini_matches && (gemini_matches.instance_of?(Array) ? !gemini_matches.empty? : gemini_matches.to_i != 0)
              begin
                gemini_matches = JSON.parse GPTK::AI::Gemini.query(
                  google_api_key, "#{repetitions_prompt}\n\nONLY output valid JSON!"
                )
              rescue
                gemini_matches = JSON.parse GPTK::AI::Gemini.query(
                  google_api_key, "#{repetitions_prompt}\n\nONLY output valid JSON!"
                )
              end
            end
          end
          puts " #{gemini_matches.count} instances detected!"
        end

        if chatgpt_client
          print 'ChatGPT is analyzing the text for repeated content...'
          begin # Retry the query if we get a bad JSON response
            chatgpt_matches = JSON.parse(GPTK::AI::ChatGPT.query(@chatgpt_client, @data, repetitions_prompt))['matches']
          rescue JSON::ParserError => e
            puts "Error: #{e.class}: '#{e.message}'. Retrying query..."
            sleep 10
            chatgpt_matches = JSON.parse(GPTK::AI::ChatGPT.query(@chatgpt_client, @data, repetitions_prompt))
              ['matches']
          end
          puts " #{chatgpt_matches.count} instances detected!"
        end

        if anthropic_api_key
          print 'Claude is analyzing the text for repeated content...'
          begin
            claude_matches = JSON.parse GPTK::AI::Claude.query_with_memory(
              anthropic_api_key, [{ role: 'user', content: repetitions_prompt }]
            )
          rescue => e
            puts "Error: #{e.class}. Retrying query..."
            sleep 10
            claude_matches = JSON.parse GPTK::AI::Claude.query_with_memory(
              anthropic_api_key, [{ role: 'user', content: repetitions_prompt }]
            )
          end
          unless claude_matches.instance_of? Array
            claude_matches = if claude_matches.key? 'matches'
                               claude_matches['matches']
                             elsif claude_matches.key? 'patterns'
                               claude_matches['patterns']
                             end
          end
          puts " #{claude_matches.count} instances detected!"
        end

        if xai_api_key
          print 'Grok is analyzing the text for repeated content...'
          grok_matches = GPTK::AI::Grok.query xai_api_key, repetitions_prompt
          grok_matches = JSON.parse(grok_matches.gsub /(```json\n)|(\n```)/, '')
          puts " #{grok_matches.count} instances detected!"
        end

        # Merge the results of each AI's analysis
        duplicate_instances = chatgpt_matches.uniq
                                             .concat(claude_matches.uniq)
                                             .concat(grok_matches.uniq)
                                             .concat(gemini_matches.uniq)

        # Remove any duplicate matches from the merged results
        puts 'Deleting any duplicate matches found...'
        duplicate_instances.delete_if do |d|
          duplicate_instances.any? do |i|
            i != d && (d['match'] == i['match'] && d['sentence_count'] == i['sentence_count'])
          end
        end
        duplicate_instances.uniq!

        # Symbolify the keys
        duplicate_instances = duplicate_instances.map { |p| Utils.symbolify_keys p }

        # Sort the matches by the order of when they appear in the chapter
        duplicate_instances.sort_by! { |d| d[:sentence_count] }

        # Print out results of the text analysis
        puts "#{duplicate_instances.count} instances of repeated content found:"
        duplicate_instances.each do |i|
          puts "- [#{i[:sentence_count]}]: #{i[:match]}"
        end

        # Create a new ChatGPT Thread
        thread_id = chatgpt_client.threads.create['id'] if agent == 'ChatGPT'

        # Prompt user for the mode
        puts 'How would you like to proceed with the revision process for the detected instances of repeated content?'
        puts 'Enter an option number: 1, or 2'
        puts 'Mode 1: Apply an operation to ALL instances of repeated content at once.'
        puts 'Mode 2: Iterate through each repeated content instance and choose an operation to apply to it.'
        mode = gets.to_i

        revised_chapter = chapter_text
        duplicates = duplicate_instances.uniq.sort_by { |i| i[:sentence_count] }
        case mode
        when 1 # Apply operation to ALL matches
          puts "Which operation do you wish to apply to all #{duplicates.count}? 1) Keep as is, 2) Change, 3) Delete"
          operation = gets.to_i

          case operation
          when 1 then puts 'Content accepted as-is.'
          when 2 # Have the first detected AI revise each instance of repeated content
            duplicates.each do |match|
              prompt = <<~STR
                Rewrite the following sentence: SENTENCE: '#{match[:sentence]}'. ONLY output the revised sentence, no other commentary or discussion.
              STR

              # Revise the chapter text based on AI feedback
              puts "Revising sentence #{match[:sentence_count]} using #{agent}..."
              puts "Original: #{match[:sentence]}"
              revised_sentence = case agent
                                 when 'ChatGPT'
                                   GPTK::AI::ChatGPT.query @chatgpt_client, @data, prompt
                                 when 'Claude'
                                   GPTK::AI::Claude.query_with_memory anthropic_api_key,
                                                                      [{ role: 'user', content: prompt }]
                                 when 'Grok'
                                   GPTK::AI::Grok.query xai_api_key, prompt
                                 when 'Gemini'
                                   GPTK::AI::Gemini.query google_api_key, prompt
                                 else raise 'Error: No AI agent detected!'
                                 end

              puts "Revision: #{revised_sentence}"
              sleep 1
              revised_chapter.gsub! match[:sentence], revised_sentence
            end

            puts "Successfully enacted #{duplicates.count} revisions!"
          when 3 # Delete all examples of bad pattern sentences
            duplicates.each do |match|
              puts 'Revising chapter...'
              puts "Sentence [#{match[:sentence_count]}] deleted: #{match[:sentence]}"
              sleep 1
              revised_chapter.gsub! match[:sentence], ''
            end
          else raise 'Invalid operation. Must be 1, 2, or 3'
          end
        when 2 # Iterate through instances of repeated content and prompt the user for action on each one
          duplicates.each do |match|
            puts "\nRepeated content: #{match[:match]}"
            puts "Sentence: #{match[:sentence]}"
            puts "Sentence number: #{match[:sentence_count]}"
            puts "Which operation do you wish to apply to the instance of repeated content?"
            puts '1) Keep as is, 2) Change, or 3) Delete'
            operation = gets.to_i

            case operation
            when 1
              puts "Ignoring repeated content: '#{match[:match]}'..."
            when 2
              puts "Would you like to 1) have #{agent} perform a rewrite of the content using its own judgement,"
              puts "or 2) would you like to provide a general prompt #{agent} will use to revise it?"
              choice = gets.to_i
              case choice
              when 1 # Have the AI auto-revise content
                prompt = <<~STR
                  Rewrite the following sentence: SENTENCE: '#{match[:sentence]}'. ONLY output the revised sentence, no other commentary or discussion.
                STR
                puts "Revising sentence #{match[:sentence_count]}..."
                revised_sentence = case agent
                                   when 'ChatGPT'
                                     GPTK::AI::ChatGPT.query @chatgpt_client, @data, prompt
                                   when 'Claude'
                                     GPTK::AI::Claude.query_with_memory anthropic_api_key,
                                                                        [{ role: 'user', content: prompt }]
                                   when 'Grok'
                                     GPTK::AI::Grok.query xai_api_key, prompt
                                   when 'Gemini'
                                     GPTK::AI::Gemini.query google_api_key, prompt
                                   else raise 'Error: No AI agent detected!'
                                   end
                puts "#{agent} revision: '#{revised_sentence}'"
                revised_chapter.gsub! match[:sentence], revised_sentence
                puts "Successfully revised the repeated content using #{agent}!"
              when 2 # Prompt user to specify prompt for the AI to use when rewriting the content
                puts "Please enter a prompt to instruct #{agent} regarding the revision of the repeated content."
                user_prompt = gets
                prompt = <<~STR
                  Rewrite the following sentence: SENTENCE: '#{match[:sentence]}'. ONLY output the revised sentence, no other commentary or discussion. #{user_prompt}
                STR
                puts "Revising sentence #{match[:sentence_count]}..."
                revised_sentence = case agent
                                   when 'ChatGPT'
                                     GPTK::AI::ChatGPT.query @chatgpt_client, @data, prompt
                                   when 'Claude'
                                     GPTK::AI::Claude.query_with_memory anthropic_api_key,
                                                                        [{ role: 'user', content: prompt }]
                                   when 'Grok'
                                     GPTK::AI::Grok.query xai_api_key, prompt
                                   when 'Gemini'
                                     GPTK::AI::Gemini.query google_api_key, prompt
                                   else raise 'Error: No AI agent detected!'
                                   end
                puts "#{agent} revision: '#{revised_sentence}'"
                revised_chapter.gsub! match[:sentence], revised_sentence
                puts "Successfully revised the repeated content using your prompt and #{agent}!"
              else raise 'Invalid option. Must be 1 or 2'
              end
            when 3 # Delete all instances of the bad pattern
              puts "Deleting sentence #{match[:sentence_count]}..."
              revised_chapter.gsub! match[:sentence], ''
              puts "Deleted: '#{match[:sentence]}'"
            else raise 'Invalid operation. Must be 1, 2, or 3'
            end
          end
        else raise 'Invalid mode. Must be 1, or 2'
        end

        # Give every sentence of the revised chapter a number, for proofreading and correcting errors later
        revised = revised_chapter.split /(?<=\.)|(?<=\!)|(?<=\?)/
        numbered_chapter = revised.map.with_index { |sentence, i| "**[#{i + 1}]** #{sentence.strip}" }.join(' ')
      ensure
        @chatgpt_client.threads.delete id: thread_id if @chatgpt_client # Garbage collection
        @last_output = revised_chapter
        puts "\nElapsed time: #{GPTK.elapsed_time start_time} minutes"
        if agent == 'Claude'
          puts "Claude memory word count: #{GPTK::Text.word_count claude_memory[:content].first[:text]}"
        end
      end

      [revised_chapter, numbered_chapter]
    end
  end
end
