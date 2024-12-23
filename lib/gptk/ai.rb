module GPTK
  # AI interfaces and tools
  # TODO: add detection of JSON string responses which will automatically parse JSON within the API call method
  module AI
    @last_output = nil # Track the cached output of the latest operation

    def self.last_output
      @last_output
    end

    # Executes a query against an AI client and processes the response.
    #
    # This method sends a query to the specified AI client (e.g., OpenAI's ChatGPT or Anthropic's Claude)
    # and returns the AI's response. It adjusts for differences between client APIs and handles token
    # usage tracking, response parsing, and error recovery in case of null outputs. The method also
    # includes a delay to prevent token throttling and race conditions.
    #
    # @param client [Object] The AI client instance, such as `OpenAI::Client` or Anthropic's Claude client.
    # @param data [Hash, nil] A hash for tracking token usage statistics. Keys include:
    #   - `:prompt_tokens` [Integer] Total tokens used in the prompt.
    #   - `:completion_tokens` [Integer] Total tokens generated by the AI.
    #   - `:cached_tokens` [Integer] Tokens retrieved from the cache, if applicable.
    # @param params [Hash] The query parameters to send to the AI client.
    #   - For OpenAI: Must include `parameters` key for the `chat` method.
    #   - For Anthropic: Must include `messages` key for the `create` method.
    #
    # @return [String] The AI's response message content as a string.
    #
    # @example Querying OpenAI's ChatGPT:
    #   client = OpenAI::Client.new(api_key: "your_api_key")
    #   data = { prompt_tokens: 0, completion_tokens: 0, cached_tokens: 0 }
    #   params = { model: "gpt-4", messages: [{ role: "user", content: "Hello!" }] }
    #   GPTK.query(client, data, params)
    #   # => "Hello! How can I assist you today?"
    #
    # @example Querying Anthropic's Claude:
    #   client = Anthropic::Client.new(api_key: "your_api_key")
    #   data = { prompt_tokens: 0, completion_tokens: 0, cached_tokens: 0 }
    #   params = { messages: [{ role: "user", content: "Tell me a story." }] }
    #   GPTK.query(client, data, params)
    #   # => "Once upon a time..."
    #
    # @note
    #   - The method automatically retries the query if the response is null.
    #   - A `sleep` delay of 1 second is included to prevent token throttling or race conditions.
    #   - The `data` hash is updated in-place with token usage statistics.
    #
    # @raise [RuntimeError] If no valid response is received after multiple retries.
    #
    # @see OpenAI::Client#chat
    # @see Anthropic::Client#messages
    def self.query(client, data, params)
      response = if client.class == OpenAI::Client
                   client.chat parameters: params
                 else # Anthropic Claude
                   client.messages.create params
                 end
      # Count token usage
      if data
        data[:prompt_tokens] += response.dig 'usage', 'prompt_tokens'
        data[:completion_tokens] += response.dig 'usage', 'completion_tokens'
        data[:cached_tokens] += response.dig 'usage', 'prompt_tokens_details', 'cached_tokens'
      end
      sleep 1 # Important to avoid race conditions and especially token throttling!
      # Return the AI's response message (object deconstruction must be ABSOLUTELY precise!)
      output = if client.instance_of? OpenAI::Client
                 response.dig 'choices', 0, 'message', 'content'
               else # Anthropic Claude
                 response.dig 'content', 0, 'text'
               end
      if output.nil?
        puts 'Error! Null output received from ChatGPT query.'
        until output
          puts 'Retrying...'
          output = client.chat parameters: params
          sleep 10
        end
      end
      output
    end

    # OpenAI's ChatGPT interface
    module ChatGPT
      # Sends a query to an AI client using a simple prompt and predefined configurations.
      #
      # This method wraps around the `AI.query` method to send a query to an AI client, using
      # predefined configurations such as model, temperature, and maximum tokens. The prompt
      # is packaged into a `messages` parameter, which is compatible with OpenAI's API.
      #
      # @param client [Object] The AI client instance, such as `OpenAI::Client`.
      # @param data [Hash] A hash for tracking token usage statistics. Keys include:
      #   - `:prompt_tokens` [Integer] Total tokens used in the prompt.
      #   - `:completion_tokens` [Integer] Total tokens generated by the AI.
      #   - `:cached_tokens` [Integer] Tokens retrieved from the cache, if applicable.
      # @param prompt [String] The text input from the user to be sent to the AI client.
      #
      # @return [String] The AI's response message content as a string, returned by `AI.query`.
      #
      # @example Querying with a prompt:
      #   client = OpenAI::Client.new(api_key: "your_api_key")
      #   data = { prompt_tokens: 0, completion_tokens: 0, cached_tokens: 0 }
      #   prompt = "What is the capital of France?"
      #   GPTK.query(client, data, prompt)
      #   # => "The capital of France is Paris."
      #
      # @note
      #   - This method uses configurations defined in `CONFIG` for parameters such as model, temperature, and max_tokens.
      #   - The `data` hash is updated in-place with token usage statistics, but tracking is currently marked as TODO.
      #   - This method assumes the client is compatible with OpenAI's `messages` API structure.
      #
      # @todo Implement proper token usage tracking.
      #
      # @see AI.query
      def self.query(client, data, prompt)
        AI.query client, data, {
          model: CONFIG[:openai_gpt_model],
          temperature: CONFIG[:openai_temperature],
          max_tokens: CONFIG[:max_tokens],
          messages: [{ role: 'user', content: prompt }]
        }
        # TODO: track token usage
      end

      # Creates a new assistant using the specified client and configuration parameters.
      #
      # This method interacts with an AI client to create a virtual assistant. It accepts various
      # parameters, such as name, instructions, description, tools, tool resources, and metadata,
      # and dynamically builds the necessary configuration for the request. The method sends the
      # request to the client and returns the unique identifier of the newly created assistant.
      #
      # @param client [Object] The AI client instance, such as `OpenAI::Client`.
      # @param name [String] The name of the assistant to be created.
      # @param instructions [String] Specific instructions for the assistant to guide its behavior.
      # @param description [String, nil] A brief description of the assistant's purpose (optional).
      # @param tools [Array, nil] A list of tools available to the assistant (optional).
      # @param tool_resources [Hash, nil] Resources required for the tools (optional).
      # @param metadata [Hash, nil] Additional metadata to configure the assistant (optional).
      #
      # @return [String] The unique identifier of the created assistant, as returned by the client.
      #
      # @example Creating an assistant with basic parameters:
      #   client = OpenAI::Client.new(api_key: "your_api_key")
      #   name = "ResearchBot"
      #   instructions = "Provide detailed answers for scientific queries."
      #   ChatGPT.create_assistant(client, name, instructions)
      #   # => "assistant_id_12345"
      #
      # @example Creating an assistant with advanced configurations:
      #   client = OpenAI::Client.new(api_key: "your_api_key")
      #   name = "SupportBot"
      #   instructions = "Assist users with troubleshooting steps."
      #   description = "A bot specialized in technical support."
      #   tools = ["KnowledgeBase", "LiveChat"]
      #   tool_resources = { "KnowledgeBase" => "https://example.com/api" }
      #   metadata = { "department" => "Customer Support" }
      #   ChatGPT.create_assistant(client, name, instructions, description, tools, tool_resources, metadata)
      #   # => "assistant_id_67890"
      #
      # @note
      #   - The `parameters` hash is dynamically updated to include optional keys only if their corresponding
      #     arguments are provided.
      #   - The method assumes that the client supports an `assistants.create` API with the given structure.
      #
      # @see OpenAI::Client#assistants.create
      def self.create_assistant(client, name, instructions, description = nil, tools = nil, tool_resources = nil, metadata = nil)
        parameters = {
          model: CONFIG[:openai_gpt_model],
          name: name,
          description: description,
          instructions: instructions
        }
        parameters.update({tools: tools}) if tools
        parameters.update({tool_resources: tool_resources}) if tool_resources
        parameters.update({metadata: metadata}) if metadata
        response = client.assistants.create parameters: parameters
        response['id']
      end

      # Executes a thread-based assistant interaction using the given prompts.
      #
      # This method manages the interaction with an AI assistant by populating a thread
      # with user messages, initiating a run, and handling the response processing. It
      # supports both single-string and array-based prompts. The method polls the status
      # of the run, retrieves messages, and returns the final assistant response.
      #
      # @param client [Object] The AI client instance, such as `OpenAI::Client`.
      # @param thread_id [String] The unique identifier of the thread to be populated and processed.
      # @param assistant_id [String] The unique identifier of the assistant to execute the run.
      # @param prompts [String, Array<String>] The user prompts to populate the thread. Can be a single string
      #   or an array of strings.
      #
      # @return [String] The final assistant response text.
      #
      # @example Running an assistant thread with a single prompt:
      #   client = OpenAI::Client.new(api_key: "your_api_key")
      #   thread_id = "thread_123"
      #   assistant_id = "assistant_456"
      #   prompts = "What are the benefits of regular exercise?"
      #   ChatGPT.run_assistant_thread(client, thread_id, assistant_id, prompts)
      #   # => "Regular exercise improves physical health, mental well-being, and overall quality of life."
      #
      # @example Running an assistant thread with multiple prompts:
      #   client = OpenAI::Client.new(api_key: "your_api_key")
      #   thread_id = "thread_789"
      #   assistant_id = "assistant_456"
      #   prompts = ["What is the capital of France?", "Explain the theory of relativity."]
      #   ChatGPT.run_assistant_thread(client, thread_id, assistant_id, prompts)
      #   # => "The capital of France is Paris. The theory of relativity..."
      #
      # @note
      #   - The method dynamically handles single-string prompts and arrays of prompts.
      #   - Polling includes a delay (`sleep`) to prevent token throttling and race conditions.
      #   - The method handles several run statuses, including `queued`, `in_progress`, `completed`, and errors.
      #   - There is a safeguard to avoid echoed responses by retrying with a new prompt.
      #
      # @todo Implement multi-page message retrieval when `has_more` is true in the message list response.
      #
      # @raise [RuntimeError] If no prompts are provided, the method will abort execution.
      #
      # @see OpenAI::Client#messages.create
      # @see OpenAI::Client#runs.create
      # @see OpenAI::Client#runs.retrieve
      # @see OpenAI::Client#messages.list
      def self.run_assistant_thread(client, thread_id, assistant_id, prompts)
        abort 'Error: no prompts given!' if prompts.empty?
        # Populate the thread with messages using given prompts
        if prompts.instance_of? String
          client.messages.create thread_id: thread_id, parameters: { role: 'user', content: prompts }
        else # Array
          prompts.each do |prompt|
            client.messages.create thread_id: thread_id, parameters: { role: 'user', content: prompt }
          end
        end

        # Create a run using given thread
        response = client.runs.create thread_id: thread_id, parameters: { assistant_id: assistant_id }
        run_id = response['id']

        # Loop while awaiting status of the run
        messages = []
        loop do
          response = client.runs.retrieve id: run_id, thread_id: thread_id
          status = response['status']

          case status
          when 'queued', 'in_progress', 'cancelling'
            puts 'Processing...'
            sleep 1
          when 'completed'
            order = 'asc'
            limit = 100
            initial_response = client.messages.list(thread_id: thread_id, parameters: { order: order, limit: limit })
            messages.concat initial_response['data']
            # TODO: FINISH THIS (multi-page paging for messages)
            # if initial_response['has_more'] == true
            #   until ['has_more'] == false
            #     messages.concat client.messages.list(thread_id: thread_id, parameters: { order: order, limit: limit })
            #   end
            # end
            break
          when 'requires_action'
            puts 'Error: unhandled "Requires Action"'
          when 'cancelled', 'failed', 'expired'
            puts response['last_error'].inspect
            break
          else
            puts "Unknown status response: #{status}"
            break
          end
        end

        # Return the response text received from the Assistant after processing the run
        response = messages.last['content'].first['text']['value']
        bad_response = prompts.instance_of?(String) ? (response == prompts) : (prompts.include? response)
        while bad_response
          puts 'Error: echoed response detected from ChatGPT. Retrying...'
          sleep 10
          response = run_assistant_thread client, thread_id, assistant_id,
                                          'Avoid repeating the input. Turn over to Claude.'
        end
        return '' if bad_response

        sleep 1 # Important to avoid race conditions and token throttling!
        response
      end
    end

    # Anthropic Claude interface
    module Claude
      # This method assumes you MUST pass either a prompt OR a messages array
      # TODO: FIX OR REMOVE THIS METHOD! CURRENTLY RETURNING 400 ERROR
      # def self.query(client, prompt: nil, messages: nil, data: nil)
      #   AI.query client, data, {
      #     model: CONFIG[:anthropic_gpt_model],
      #     max_tokens: CONFIG[:anthropic_max_tokens],
      #     messages: messages || [{ role: 'user', content: prompt }]
      #   }
      # end

      # Sends a query to the Claude API, utilizing memory for context and tracking.
      #
      # This method sends user messages to the Claude API and retrieves a response. It handles
      # string-based or array-based inputs, dynamically constructs the request body and headers,
      # and parses the response for the AI's output. If errors occur, the method retries the query.
      #
      # @param api_key [String] The API key for accessing the Claude API.
      # @param messages [String, Array<Hash>] The user input to be sent to the Claude API. If a string
      #   is provided, it is converted into an array of message hashes with `role` and `content` keys.
      #
      # @return [String] The AI's response text.
      #
      # @example Sending a single message as a string:
      #   api_key = "your_anthropic_api_key"
      #   messages = "What is the capital of Italy?"
      #   Claude.query_with_memory(api_key, messages)
      #   # => "The capital of Italy is Rome."
      #
      # @example Sending multiple messages as an array:
      #   api_key = "your_anthropic_api_key"
      #   messages = [
      #     { role: "user", content: "Tell me a joke." },
      #     { role: "user", content: "Explain quantum mechanics simply." }
      #   ]
      #   Claude.query_with_memory(api_key, messages)
      #   # => "Here’s a joke: Why did the physicist cross the road? To observe the other side!"
      #
      # @note
      #   - The method retries the query in case of errors, such as network failures, JSON parsing errors,
      #     or bad responses from the Claude API.
      #   - A delay (`sleep 1`) is included to prevent token throttling and race conditions.
      #   - The method currently lacks data tracking functionality (marked as TODO).
      #
      # @raise [JSON::ParserError] If the response body cannot be parsed as JSON.
      # @raise [RuntimeError] If no valid response is received after retries.
      #
      # @see HTTParty.post
      # @see JSON.parse
      def self.query_with_memory(api_key, messages)
        messages = messages.instance_of?(String) ? [{ role: 'user', content: messages }] : messages
        headers = {
          'x-api-key' => api_key,
          'anthropic-version' => '2023-06-01',
          'content-type' => 'application/json',
          'anthropic-beta' => 'prompt-caching-2024-07-31'
        }
        body = {
          'model': CONFIG[:anthropic_gpt_model],
          'max_tokens': CONFIG[:anthropic_max_tokens],
          'messages': messages
        }
        begin
          response = HTTParty.post(
            'https://api.anthropic.com/v1/messages',
            headers: headers,
            body: body.to_json
          )
          # TODO: track data
          # Return text content of the Claude API response
        rescue => e # We want to catch ALL errors, not just those under StandardError
          puts "Error: #{e.class}: '#{e.message}'. Retrying query..."
          sleep 10
          output = query_with_memory api_key, messages
        end
        sleep 1 # Important to avoid race conditions and especially token throttling!
        begin
          output = JSON.parse(response.body).dig 'content', 0, 'text'
        rescue JSON::ParserError => e
          puts "Error: #{e.class}. Retrying query..."
          sleep 10
          output = query_with_memory api_key, messages
        end
        if output.nil?
          ap JSON.parse response.body
          puts 'Error: Claude API provided a bad response. Retrying query...'
          sleep 10
          output = query_with_memory api_key, messages
        end
        output
      end
    end

    module Grok
      # Sends a query to the Grok API and retrieves the AI's response.
      #
      # This method constructs an HTTP request to the Grok API, sending a user prompt and optional
      # system instructions. It handles both single-string and array-based prompts, dynamically
      # builds the request payload, and parses the response for the AI's output. If errors occur,
      # the method retries the query.
      #
      # @param api_key [String] The API key for accessing the Grok API.
      # @param prompt [String, Array<String>] The user input to send to the Grok API. Can be a single string
      #   or an array of strings.
      # @param system_prompt [String, nil] Optional system-level instructions to prepend to the message array.
      #
      # @return [String] The AI's response text.
      #
      # @example Sending a single prompt to the Grok API:
      #   api_key = "your_grok_api_key"
      #   prompt = "Explain the importance of biodiversity."
      #   Grok.query(api_key, prompt)
      #   # => "Biodiversity is crucial for ecosystem resilience and human survival."
      #
      # @example Sending multiple prompts with a system instruction:
      #   api_key = "your_grok_api_key"
      #   prompt = ["What is AI?", "How does machine learning work?"]
      #   system_prompt = "You are an AI educator."
      #   Grok.query(api_key, prompt, system_prompt)
      #   # => "AI, or Artificial Intelligence, refers to the simulation of human intelligence in machines..."
      #
      # @note
      #   - The method retries queries in case of network or JSON parsing errors.
      #   - A delay (`sleep 1`) is included to prevent token throttling and race conditions.
      #   - The method supports both single-string and array-based prompts.
      #   - Currently, token usage tracking is marked as TODO.
      #
      # @raise [RuntimeError] If no valid response is received after multiple retries.
      # @raise [JSON::ParserError] If the response body cannot be parsed as JSON.
      #
      # @see HTTParty.post
      # @see JSON.parse
      #
      # @todo Look into and possibly write a fix for repeated JSON parsing errors (looping)
      def self.query(api_key, prompt, system_prompt = nil)
        headers = {
          'Authorization' => "Bearer #{api_key}",
          'content-type' => 'application/json'
        }
        messages = if prompt.instance_of?(Array)
                     prompt.collect { |p| { 'role': 'user', 'content': p } }
                   else
                     [{ 'role': 'user', 'content': prompt }]
                   end
        messages.prepend({ 'role': 'system', 'content': system_prompt }) if system_prompt
        body = {
          'model': CONFIG[:xai_gpt_model],
          'stream': false,
          'temperature': CONFIG[:xai_temperature],
          'messages': messages
        }

        max_retries = 5
        retries = 0

        begin
          response = HTTParty.post(
            'https://api.x.ai/v1/chat/completions',
            headers: headers,
            body: body.to_json
          )

          # Check if the response is nil or not successful
          if response.nil? || response.code != 200
            raise "Unexpected response: #{response.inspect}"
          end

          parsed_response = JSON.parse(response.body)
          output = parsed_response.dig('choices', 0, 'message', 'content')

          if output.nil? || output.empty?
            raise "Empty or nil output received: #{parsed_response.inspect}"
          end

          output
        rescue Net::ReadTimeout => e
          puts "Network timeout occurred: #{e.class}. Retrying query..."
          retries += 1
          if retries <= max_retries
            sleep(5)
            retry
          else
            raise "Exceeded maximum retries due to timeout errors."
          end
        rescue JSON::ParserError => e
          puts "JSON parsing error: #{e.class}. Raw response: #{response&.body.inspect}"
          retries += 1
          if retries <= max_retries
            sleep(5)
            retry
          else
            raise "Exceeded maximum retries due to JSON parsing errors."
          end
        rescue => e
          puts "Unexpected Error: #{e.class}: #{e.message}. Raw Response: #{response&.body.inspect}"
          retries += 1
          if retries <= max_retries
            sleep(5)
            retry
          else
            raise "Exceeded maximum retries due to unexpected errors."
          end
        end
      end
    end

    # Google's Gemini
    module Gemini
      BASE_URL = 'https://generativelanguage.googleapis.com/v1beta'

      # Sends a query to the Gemini API and retrieves the AI's response.
      #
      # This method constructs an HTTP request to the Gemini API, sending a user prompt and specifying
      # the model to use. It processes the response to extract the AI's output text. The method includes
      # retry logic to handle errors such as JSON parsing issues or bad responses.
      #
      # @param api_key [String] The API key for accessing the Gemini API.
      # @param prompt [String] The user input to be sent to the Gemini API.
      # @param model [String] The AI model to use for processing the prompt. Defaults to the value of
      #   `CONFIG[:google_gpt_model]`.
      #
      # @return [String] The AI's response text.
      #
      # @example Querying the Gemini API with a prompt:
      #   api_key = "your_gemini_api_key"
      #   prompt = "What is the role of photosynthesis in plants?"
      #   Gemini.query(api_key, prompt)
      #   # => "Photosynthesis allows plants to convert light energy into chemical energy stored in glucose."
      #
      # @note
      #   - The method retries queries in case of network errors or JSON parsing failures.
      #   - A delay (`sleep 1`) is included to prevent token throttling and race conditions.
      #   - Token usage tracking is marked as TODO.
      #
      # @raise [JSON::ParserError] If the response body cannot be parsed as JSON.
      # @raise [RuntimeError] If no valid response is received after multiple retries.
      #
      # @see HTTParty.post
      # @see JSON.parse
      def self.query(api_key, prompt, model = CONFIG[:google_gpt_model])
        # Gemini manual HTTP API call
        body = { 'contents': [{ 'parts': [{ 'text': prompt }] }] }
        response = HTTParty.post(
          "#{BASE_URL}/models/#{model}:generateContent?key=#{api_key}",
          headers: { 'content-type' => 'application/json' },
          body: body.to_json
        )
        # TODO: track data
        # Return text content of the Gemini API response
        sleep 1 # Important to avoid race conditions and token throttling!
        begin
          output = JSON.parse(response.body).dig 'candidates', 0, 'content', 'parts', 0, 'text'
        rescue JSON::ParserError => e # We want to catch ALL errors, not just those under StandardError
          puts "Error: #{e.class}. Retrying query..."
          sleep 10
          output = query api_key, prompt
        end
        if output.nil?
          ap JSON.parse response.body
          puts 'Error: Gemini API provided a bad response. Retrying query...'
          sleep 10
          output = query api_key, prompt
        end
        output
      end

      # Sends a cached query to the Gemini API and retrieves the AI's response.
      #
      # This method constructs an HTTP request to the Gemini API using the provided API key, body, and model.
      # It processes the response to extract the AI's output text. The method includes retry logic to handle
      # errors, such as JSON parsing failures or bad responses, and is designed for use with cached requests.
      #
      # @param api_key [String] The API key for accessing the Gemini API.
      # @param body [Hash] The request body to send to the Gemini API. This includes prompt data and other
      #   configuration options.
      # @param model [String] The AI model to use for processing the request. Defaults to the value of
      #   `CONFIG[:google_gpt_model]`.
      #
      # @return [String] The AI's response text.
      #
      # @example Sending a cached query to the Gemini API:
      #   api_key = "your_gemini_api_key"
      #   body = {
      #     'contents': [{ 'parts': [{ 'text': "What is the capital of Japan?" }] }]
      #   }
      #   Gemini.query_with_cache(api_key, body)
      #   # => "The capital of Japan is Tokyo."
      #
      # @note
      #   - The method retries queries in case of network errors or JSON parsing failures.
      #   - A delay (`sleep 1`) is included to prevent token throttling and race conditions.
      #   - The method is designed to work with cached queries and currently lacks explicit
      #     tracking functionality (marked as TODO).
      #
      # @raise [JSON::ParserError] If the response body cannot be parsed as JSON.
      # @raise [RuntimeError] If no valid response is received after multiple retries.
      #
      # @see HTTParty.post
      # @see JSON.parse
      def self.query_with_cache(api_key, body, model = CONFIG[:google_gpt_model])
        max_retries = 5
        retries = 0

        begin
          response = HTTParty.post(
            "#{BASE_URL}/models/#{model}-001:generateContent?key=#{api_key}",
            headers: { 'content-type' => 'application/json' },
            body: body.to_json
          )

          # Explicitly check the response body for nil or empty
          if response.body.nil? || response.body.empty?
            raise "Unexpected response: Body is nil or empty."
          end

          # Parse the response to extract the output
          output = JSON.parse(response.body).dig('candidates', 0, 'content', 'parts', 0, 'text')

          # Check if the output is nil or empty
          if output.nil? || output.empty?
            raise "Empty or nil output received: #{response.body.inspect}"
          end

          return output
        rescue JSON::ParserError => e
          puts "JSON Parsing Error: #{e.class}: #{e.message}. Retrying..."
          retries += 1
          if retries <= max_retries
            sleep(5)
            retry
          else
            raise "Exceeded maximum retries due to JSON parsing errors."
          end
        rescue Errno::ECONNRESET, Net::ReadTimeout => e
          puts "Network Error: #{e.class}: #{e.message}. Retrying..."
          retries += 1
          if retries <= max_retries
            sleep(5)
            retry
          else
            raise "Exceeded maximum retries due to network errors."
          end
        rescue => e
          puts "Unexpected Error: #{e.class}: #{e.message}. Raw Response: #{response&.body.inspect}"
          retries += 1
          if retries <= max_retries
            sleep(5)
            retry
          else
            raise "Exceeded maximum retries due to unexpected errors."
          end
        end
      end
    end

    # Categorizes a list of items based on provided categories using an AI model.
    #
    # This method sends prompts to an AI model to categorize a given list of items into specified
    # categories. It iterates through the items, constructs categorization prompts, and collects
    # responses from the AI. The results are grouped by category and returned as a hash. Errors
    # and progress are logged throughout the process.
    #
    # @param doc [Object] An instance containing the AI client and data context for querying.
    # @param items [Array<String>] The list of items to be categorized.
    # @param categories [String] A string describing the available categories, typically enumerated.
    #
    # @return [Hash] A hash where keys are category numbers (integers) and values are arrays of items
    #   belonging to those categories.
    #
    # @example Categorizing a list of items:
    #   doc = Document.new(client: ChatGPT::Client.new, data: { prompt_tokens: 0 })
    #   items = ["Apple", "Carrot", "Chicken"]
    #   categories = "1. Fruit\n2. Vegetable\n3. Protein"
    #   AI.categorize_items(doc, items, categories)
    #   # => { 1 => ["Apple"], 2 => ["Carrot"], 3 => ["Chicken"] }
    #
    # @note
    #   - The method aborts execution if the `items` or `categories` are empty.
    #   - The AI prompt is dynamically constructed for each item using the categories.
    #   - Progress is logged to the console during the operation.
    #   - Results are cached in the `@last_output` instance variable for reuse.
    #
    # @raise [RuntimeError] If the AI fails to generate a viable response.
    # @raise [Abort] If the input items or categories are empty, or no output is generated.
    #
    # @see ChatGPT.query
    def self.categorize_items(doc, items, categories)
      abort 'Error: no items found!' if items.empty?
      abort 'Error: no categories found!' if categories.empty?
      puts "Categorizing #{items.count} items..."
      i = 0
      results = items.group_by do |item|
        prompt = "Based on the following categories:\n\n#{categories}\n\nPlease categorize the following prompt:\n\n#{item}\n\nPlease return JUST the category number, and no other output text."
        # Send the prompt to the AI using the chat API, and retrieve the response
        begin
          content = ChatGPT.query doc.client, prompt, doc.data
        rescue StandardError => e
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
      puts 'Error: no output!' unless results && !results.empty?
      puts "Successfully categorized #{results.values.reduce(0) {|j, loe| j += loe.count; j }} items!"
      @last_output = results # Cache results of the complete operation
      results
    end
  end
end
