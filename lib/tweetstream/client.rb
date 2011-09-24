require 'uri'
require 'cgi'
require 'eventmachine'
require 'twitter/json_stream'
require 'multi_json'

module TweetStream
  # Provides simple access to the Twitter Streaming API (http://apiwiki.twitter.com/Streaming-API-Documentation)
  # for Ruby scripts that need to create a long connection to
  # Twitter for tracking and other purposes.
  #
  # Basic usage of the library is to call one of the provided
  # methods and provide a block that will perform actions on
  # a yielded TweetStream::Status. For example:
  #
  #     TweetStream::Client.new('user','pass').track('fail') do |status|
  #       puts "[#{status.user.screen_name}] #{status.text}"
  #     end
  #
  # For information about a daemonized TweetStream client,
  # view the TweetStream::Daemon class.
  class Client
    attr_accessor :username, :password
    attr_reader :parser

    # @private
    attr_accessor *Configuration::VALID_OPTIONS_KEYS

    # Creates a new API
    def initialize(options={})
      options = TweetStream.options.merge(options)
      Configuration::VALID_OPTIONS_KEYS.each do |key|
        send("#{key}=", options[key])
      end
    end

    # Get the JSON parser class for this client.
    def json_parser
      parser_from(parser)
    end

    # Create a new client with the Twitter credentials
    # of the account you want to be using its API quota.
    # You may also set the JSON parsing library as specified
    # in the #parser= setter.
    # def initialize(ouser, pass, parser = :json_gem)
    #   self.username = user
    #   self.password = pass
    #   self.parser = parser
    # end

    # Returns all public statuses. The Firehose is not a generally
    # available resource. Few applications require this level of access.
    # Creative use of a combination of other resources and various access
    # levels can satisfy nearly every application use case.
    def firehose(query_parameters = {}, &block)
      start('statuses/firehose', query_parameters, &block)
    end

    # Returns all retweets. The retweet stream is not a generally available
    # resource. Few applications require this level of access. Creative
    # use of a combination of other resources and various access levels
    # can satisfy nearly every application use case. As of 9/11/2009,
    # the site-wide retweet feature has not yet launched,
    # so there are currently few, if any, retweets on this stream.
    def retweet(query_parameters = {}, &block)
      start('statuses/retweet', query_parameters, &block)
    end

    # Returns a random sample of all public statuses. The default access level
    # provides a small proportion of the Firehose. The "Gardenhose" access
    # level provides a proportion more suitable for data mining and
    # research applications that desire a larger proportion to be statistically
    # significant sample.
    def sample(query_parameters = {}, &block)
      start('statuses/sample', query_parameters, &block)
    end

    # Specify keywords to track. Queries are subject to Track Limitations,
    # described in Track Limiting and subject to access roles, described in
    # the statuses/filter method. Track keywords are case-insensitive logical
    # ORs. Terms are exact-matched, and also exact-matched ignoring
    # punctuation. Phrases, keywords with spaces, are not supported.
    # Keywords containing punctuation will only exact match tokens.
    # Query parameters may be passed as the last argument.
    def track(*keywords, &block)
      query_params = keywords.pop if keywords.last.is_a?(::Hash)
      query_params ||= {}
      filter(query_params.merge(:track => keywords), &block)
    end

    # Returns public statuses from or in reply to a set of users. Mentions
    # ("Hello @user!") and implicit replies ("@user Hello!" created without
    # pressing the reply "swoosh") are not matched. Requires integer user
    # IDs, not screen names. Query parameters may be passed as the last argument.
    def follow(*user_ids, &block)
      query_params = user_ids.pop if user_ids.last.is_a?(::Hash)
      query_params ||= {}
      filter(query_params.merge(:follow => user_ids), &block)
    end

    # Specifies a set of bounding boxes to track. Only tweets that are both created
    # using the Geotagging API and are placed from within a tracked bounding box will
    # be included in the stream – the user’s location field is not used to filter tweets
    # (e.g. if a user has their location set to “San Francisco”, but the tweet was not created
    # using the Geotagging API and has no geo element, it will not be included in the stream).
    # Bounding boxes are specified as a comma separate list of longitude/latitude pairs, with
    # the first pair denoting the southwest corner of the box
    # longitude/latitude pairs, separated by commas. The first pair specifies the southwest corner of the box.
    def locations(*locations_map, &block)
        query_params = locations_map.pop if locations_map.last.is_a?(::Hash)
        query_params ||= {}
        filter(query_params.merge(:locations => locations_map), &block)
    end

    # Make a call to the statuses/filter method of the Streaming API,
    # you may provide <tt>:follow</tt>, <tt>:track</tt> or both as options
    # to follow the tweets of specified users or track keywords. This
    # method is provided separately for cases when it would conserve the
    # number of HTTP connections to combine track and follow.
    def filter(query_params = {}, &block)
      start('statuses/filter', query_params.merge(:method => :post), &block)
    end

    # Make a call to the statuses/filter method of the Streaming API,
    # you may provide <tt>:follow</tt>, <tt>:track</tt> or both as options
    # to follow the tweets of specified users or track keywords. This
    # method is provided separately for cases when it would conserve the
    # number of HTTP connections to combine track and follow.
    def user_stream(&block)
      start('', :extra_stream_parameters => {:host => "userstream.twitter.com", :path => "/2/user.json"}, &block)
    end

    # Set a Proc to be run when a deletion notice is received
    # from the Twitter stream. For example:
    #
    #     @client = TweetStream::Client.new('user','pass')
    #     @client.on_delete do |status_id, user_id|
    #       Tweet.delete(status_id)
    #     end
    #
    # Block must take two arguments: the status id and the user id.
    # If no block is given, it will return the currently set
    # deletion proc. When a block is given, the TweetStream::Client
    # object is returned to allow for chaining.
    def on_delete(&block)
      if block_given?
        @on_delete = block
        self
      else
        @on_delete
      end
    end

    # Set a Proc to be run when a rate limit notice is received
    # from the Twitter stream. For example:
    #
    #     @client = TweetStream::Client.new('user','pass')
    #     @client.on_limit do |discarded_count|
    #       # Make note of discarded count
    #     end
    #
    # Block must take one argument: the number of discarded tweets.
    # If no block is given, it will return the currently set
    # limit proc. When a block is given, the TweetStream::Client
    # object is returned to allow for chaining.
    def on_limit(&block)
      if block_given?
        @on_limit = block
        self
      else
        @on_limit
      end
    end

    # Set a Proc to be run when an HTTP error is encountered in the
    # processing of the stream. Note that TweetStream will automatically
    # try to reconnect, this is for reference only. Don't panic!
    #
    #     @client = TweetStream::Client.new('user','pass')
    #     @client.on_error do |message|
    #       # Make note of error message
    #     end
    #
    # Block must take one argument: the error message.
    # If no block is given, it will return the currently set
    # error proc. When a block is given, the TweetStream::Client
    # object is returned to allow for chaining.
    def on_error(&block)
      if block_given?
        @on_error = block
        self
      else
        @on_error
      end
    end

    # Set a Proc to be run when a direct message is encountered in the
    # processing of the stream.
    #
    #     @client = TweetStream::Client.new('user','pass')
    #     @client.on_error do |direct_message|
    #       # do something with the direct message
    #     end
    #
    # Block must take one argument: the direct message.
    # If no block is given, it will return the currently set
    # direct message proc. When a block is given, the TweetStream::Client
    # object is returned to allow for chaining.
    def on_direct_message(&block)
      if block_given?
        @on_direct_message = block
        self
      else
        @on_direct_message
      end
    end

    # Set a Proc to be run when connection established.
    # Called in EventMachine::Connection#post_init
    #
    #     @client = TweetStream::Client.new('user','pass')
    #     @client.on_inited do
    #       puts 'Connected...'
    #     end
    #
    def on_inited(&block)
      if block_given?
        @on_inited = block
        self
      else
        @on_inited
      end
    end

    def start(path, query_parameters = {}, &block) #:nodoc:
      method = query_parameters.delete(:method) || :get
      delete_proc = query_parameters.delete(:delete) || self.on_delete
      limit_proc = query_parameters.delete(:limit) || self.on_limit
      error_proc = query_parameters.delete(:error) || self.on_error
      inited_proc = query_parameters.delete(:inited) || self.on_inited
      direct_message_proc = query_parameters.delete(:direct_message) || self.on_direct_message

      params = normalize_filter_parameters(query_parameters)

      extra_stream_parameters = query_parameters.delete(:extra_stream_parameters) || {}

      uri = method == :get ? build_uri(path, params) : build_uri(path)

      stream_params = {
        :path       => uri,
        :method     => method.to_s.upcase,
        :user_agent => user_agent,
        :on_inited  => inited_proc,
        :filters    => params.delete(:track),
        :params     => params,
        :ssl        => true
      }.merge(auth_params).merge(extra_stream_parameters)

      EventMachine::run {
        @stream = Twitter::JSONStream.connect(stream_params)
        @stream.each_item do |item|
          begin
            raw_hash = json_parser.decode(item)
          rescue MultiJson::DecodeError => ex
            error_proc.call("MultiJson::DecodeError occured in stream: #{item}") if error_proc.is_a?(Proc)
            next
          end

          unless raw_hash.is_a?(::Hash)
            error_proc.call("Unexpected JSON object in stream: #{item}") if error_proc.is_a?(Proc)
            next
          end

          hash = TweetStream::Hash.new(raw_hash)

          if hash[:delete] && hash[:delete][:status]
            delete_proc.call(hash[:delete][:status][:id], hash[:delete][:status][:user_id]) if delete_proc.is_a?(Proc)
          elsif hash[:limit] && hash[:limit][:track]
            limit_proc.call(hash[:limit][:track]) if limit_proc.is_a?(Proc)

          elsif hash[:direct_message]
            if direct_message_proc.is_a?(Proc)
              case direct_message_proc.arity
              when 1
                direct_message_proc.call(TweetStream::DirectMessage.new(hash[:direct_message]))
              when 2
                direct_message_proc.call(TweetStream::DirectMessage.new(hash[:direct_message]), self)
              end
            end

          elsif hash[:text] && hash[:user]
            @last_status = TweetStream::Status.new(hash)

            # Give the block the option to receive either one
            # or two arguments, depending on its arity.
            case block.arity
              when 1
                yield @last_status
              when 2
                yield @last_status, self
            end
          end
        end

        @stream.on_error do |message|
          error_proc.call(message) if error_proc.is_a?(Proc)
        end

        @stream.on_max_reconnects do |timeout, retries|
          raise TweetStream::ReconnectError.new(timeout, retries)
        end
      }
    end

    # Terminate the currently running TweetStream.
    def stop
      EventMachine.stop_event_loop
      @last_status
    end

    protected

    def parser_from(parser)
      MultiJson.engine = parser
      MultiJson
    end

    def build_uri(path, query_parameters = {}) #:nodoc:
      URI.parse("/1/#{path}.json#{build_query_parameters(query_parameters)}")
    end

    def build_query_parameters(query)
      query.size > 0 ? "?#{build_post_body(query)}" : ''
    end

    def build_post_body(query) #:nodoc:
      return '' unless query && query.is_a?(::Hash) && query.size > 0
      pairs = []

      query.each_pair do |k,v|
        v = v.flatten.collect { |q| q.to_s }.join(',') if v.is_a?(Array)
        pairs << "#{k.to_s}=#{CGI.escape(v.to_s)}"
      end

      pairs.join('&')
    end

    def normalize_filter_parameters(query_parameters = {})
      [:follow, :track, :locations].each do |param|
        if query_parameters[param].kind_of?(Array)
          query_parameters[param] = query_parameters[param].flatten.collect{|q| q.to_s}.join(',')
        elsif query_parameters[param]
          query_parameters[param] = query_parameters[param].to_s
        end
      end
      query_parameters
    end

    def auth_params
      case auth_method
      when :basic
        return :auth => "#{username}:#{password}"
      when :oauth
        return :oauth => {
          :consumer_key => consumer_key,
          :consumer_secret => consumer_secret,
          :access_key => oauth_token,
          :access_secret => oauth_token_secret
        }
      end
    end
  end
end
