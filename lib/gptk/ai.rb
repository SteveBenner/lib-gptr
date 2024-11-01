module GPTK
  module AI
    @last_output = nil # Track the cached output of the latest operation
    def self.last_output
      @last_output
    end

    # Run a single AI API query (generic) and return the results of a single prompt
    def self.query(client, prompt, data)
      response = client.chat(
        parameters: {
          model: CONFIG[:openai_gpt_model],
          messages: [{ role: 'user', content: prompt }],
          temperature: CONFIG[:openai_temperature],
          max_tokens: CONFIG[:max_tokens]
        }
      )
      # Count token usage
      data[:prompt_tokens] += response.dig 'usage', 'prompt_tokens'
      data[:completion_tokens] += response.dig 'usage', 'completion_tokens'
      data[:cached_tokens] += response.dig 'usage', 'prompt_tokens_details', 'cached_tokens'
      # Return the AI's response message
      response.dig 'choices', 0, 'message', 'content' # This must be ABSOLUTELY precise!
    end

    # Query a an AI for categorization of each and every item in a given set
    # @param [GPTK::Doc] doc
    # @param [Array] items
    # @param [Hash<Integer => Hash<title: String, description: String>>] categories
    # @return [Hash<Integer => Array<String>>] categorized items
    def self.categorize_items(doc, items, categories)
      abort 'Error: no items found!' if items.empty?
      abort 'Error: no categories found!' if categories.empty?
      puts "Categorizing #{items.count} items..."
      i = 0
      results = items.group_by do |item|
        prompt = "Based on the following categories:\n\n#{categories}\n\nPlease categorize the following prompt:\n\n#{item}\n\nPlease return JUST the category number, and no other output text."
        # Send the prompt to the AI using the chat API, and retrieve the response
        begin
          content = query doc.client, prompt, doc.data
        rescue => e
          puts "Error: #{e.class}: #{e.message}"
          puts 'Please try operation again, or review the code.'
          puts 'Last operation response:'
          print content
          return content
        end
        abort 'Error: failed to generate a viable response!' unless content
        puts "#{((i.to_f / items.count) * 100).round 3}% complete..."
        i += 1
        content.to_i
      end
      abort 'Error: no output!' unless results && !results.empty?
      puts "Successfully categorized #{results.values.reduce(0) {|j, loe| j += loe.count; j }} items!"
      @last_output = results # Cache results of the complete operation
      results
    end
  end
end
