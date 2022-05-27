# encoding: utf-8
require "logstash/inputs/threadable"
require "logstash/json"
require "logstash/namespace"
require "logstash/timestamp"
require "logstash/plugin_mixins/aws_config"
require "logstash/errors"
require 'logstash/inputs/sqs/patch'

# Forcibly load all modules marked to be lazily loaded.
#
# It is recommended that this is called prior to launching threads. See
# https://aws.amazon.com/blogs/developer/threading-with-the-aws-sdk-for-ruby/.
Aws.eager_autoload!

def jsonify_hash(hash)
  hash.map { |k,v| [k.to_s, LogStash::Json.dump(v)] }.to_h
end

def create_queue_raw(sqs_client, queue_name, attributes, tags)
  sqs_resource = Aws::SQS::Resource.new(client: sqs_client)

  return sqs_resource.create_queue(
      queue_name: queue_name, 
      attributes: jsonify_hash(attributes), 
      tags: tags,
  )
rescue Aws::SQS::Errors::QueueNameExists
  sqs_resource = Aws::SQS::Resource.new(client: sqs_client)

  queue_url = sqs_client.get_queue_url(queue_name).queue_url

  existing_tags = sqs_client.list_queue_tags(queue_url: queue_url).tags

  tags_to_remove = existing_tags.keys - tags.keys

  sqs_client.tag_queue(queue_url: queue_url, tags: tags)

  if tags_to_remove
      sqs_client.untag_queue(queue_url: queue_url, tag_keys: tags_to_remove)
  end

  # Run create again to make sure everything matches.
  return sqs_resource.create_queue(
      queue_name: queue_name, 
      attributes: jsonify_hash(attributes), 
      tags: tags,
  )
end


def create_queue(sqs_client, queue_name, **kwargs) 
  tags = kwargs.delete('tags') || {}

  dead_letter_queue = create_queue_raw(
      sqs_client,
      "#{queue_name}-dead-letter",
      {"MessageRetentionPeriod" => 1209600},  # maximum (14 days)
      {"dlq" => "true", **tags},
  )

  dead_letter_queue_arn = dead_letter_queue.attributes["QueueArn"]

  redrive_policy_kwargs = kwargs.delete("RedrivePolicy") || {}

  redrivePolicy = {"maxReceiveCount" => 5}.merge(redrive_policy_kwargs)
  redrivePolicy["deadLetterTargetArn"] = dead_letter_queue_arn

  return create_queue_raw(
      sqs_client,
      queue_name, 
      {"RedrivePolicy" => redrivePolicy }, 
      tags,
  )
end


class LogStash::Inputs::TQP < LogStash::Inputs::Threadable
  include LogStash::PluginMixins::AwsConfig::V2

  MAX_TIME_BEFORE_GIVING_UP = 60
  MAX_MESSAGES_TO_FETCH = 10 # Between 1-10 in the AWS-SDK doc
  SQS_ATTRIBUTES = ['All']
  BACKOFF_SLEEP_TIME = 1
  BACKOFF_FACTOR = 2
  DEFAULT_POLLING_FREQUENCY = 20

  config_name "tqp"

  default :codec, "json"

  config :additional_settings, :validate => :hash, :default => {}

  config :queue_name, :validate => :string
  config :prefix, :validate => :string
  config :topics, :validate => :array
  
  # Polling frequency, default is 20 seconds
  config :polling_frequency, :validate => :number, :default => DEFAULT_POLLING_FREQUENCY

  attr_reader :poller

  def register
    require "aws-sdk"
    @logger.info("Registering SQS input", 
      queue_name: @queue_name,
    )

    setup_queue
  end

  def setup_queue
    sqs_client = Aws::SQS::Client.new()
    
    @sqs_queue = create_queue(sqs_client, "#{prefix}--#{queue_name}")

    subscribe_to_topics(sqs_client)

    poller = Aws::SQS::QueuePoller.new(@sqs_queue.url, client: sqs_client)
    poller.before_request { |stats| throw :stop_polling if stop? }

    @poller = poller
  rescue Aws::SQS::Errors::ServiceError, Seahorse::Client::NetworkingError => e
    @logger.error("Cannot establish connection to Amazon SQS", exception_details(e))
    raise LogStash::ConfigurationError, "Verify the SQS queue name and your credentials"
  end

  def subscribe_to_topics(sqs_client)
    sns_client = Aws::SNS::Resource.new()

    queue_arn = @sqs_queue.attributes["QueueArn"]

    topic_arns = []

    topics.each do |topic|
      topic = "#{topic[0]}--#{topic[1]}" if topic.kind_of?(Array)

      @logger.debug("Subscribing to topic", topic: "#{prefix}--#{topic}")

      topic = sns_client.create_topic(name: "#{prefix}--#{topic}")
      topic.subscribe(protocol: "sqs", endpoint: queue_arn)

      topic_arns.push(topic.arn)
    end 


    @sqs_queue.set_attributes(
      attributes: jsonify_hash({
        "Policy" => {
          "Version" => "2012-10-17", 
          "Statement" => [
              {
                "Sid" => "sns",
                "Effect" => "Allow",
                "Principal" => {"AWS" => "*"},
                "Action" => "SQS:SendMessage",
                "Resource" => queue_arn,
                "Condition" => {"ArnEquals" => {"aws:SourceArn" => topic_arns}},
            }
          ]
        }
      })
    )

  end 

  def polling_options
    { 
      :max_number_of_messages => MAX_MESSAGES_TO_FETCH,
      :attribute_names => SQS_ATTRIBUTES,
      :wait_time_seconds => @polling_frequency
    }
  end

  def add_sns_data(event, message)
    body = LogStash::Json.load(message.body)

    topic = body["TopicArn"].split(":")[-1]
    topic = topic.delete_prefix("#{prefix}--") if prefix

    message = LogStash::Json.load(body.delete("Message") || '{}')

    event.set('[@metadata][topic]', topic)
    event.set('[@metadata][body]', body)
    
    message.each do |key, value| 
      event.set(key, value)
    end
  end 

  def handle_message(message, output_queue)
    event = LogStash::Event.new("message" => @message, "host" => @host)

    add_sns_data(event, message)

    decorate(event)
    output_queue << event
  end

  def run(output_queue)
    @logger.debug("Polling SQS queue", polling_options: polling_options)

    run_with_backoff do
      poller.poll(polling_options) do |messages, stats|
        break if stop?
        
        messages.each {|message| 
          handle_message(message, output_queue) 
        }

        @logger.debug(
          "SQS Stats:", 
          request_count: stats.request_count,
          received_message_count: stats.received_message_count,
          last_message_received_at: stats.last_message_received_at
        ) if @logger.debug?
      end
    end
  end

  private

  # Runs an AWS request inside a Ruby block with an exponential backoff in case
  # we experience a ServiceError.
  #
  # @param [Block] block Ruby code block to execute.
  def run_with_backoff(&block)
    sleep_time = BACKOFF_SLEEP_TIME
    begin
      block.call
    rescue Aws::SQS::Errors::ServiceError, Seahorse::Client::NetworkingError => e
      @logger.warn("SQS error ... retrying with exponential backoff", exception_details(e, sleep_time))
      sleep_time = backoff_sleep(sleep_time)
      retry
    end
  end

  def backoff_sleep(sleep_time)
    sleep(sleep_time)
    sleep_time > MAX_TIME_BEFORE_GIVING_UP ? sleep_time : sleep_time * BACKOFF_FACTOR
  end

  def convert_epoch_to_timestamp(time)
    LogStash::Timestamp.at(time.to_i / 1000)
  end

  def exception_details(e, sleep_time = nil)
    details = { :queue_name => @queue_name, :exception => e.class, :message => e.message }
    details[:code] = e.code if e.is_a?(Aws::SQS::Errors::ServiceError) && e.code
    details[:cause] = e.original_error if e.respond_to?(:original_error) && e.original_error # Seahorse::Client::NetworkingError
    details[:sleep_time] = sleep_time if sleep_time
    details[:backtrace] = e.backtrace if @logger.debug?
    details
  end

end # class LogStash::Inputs::TQP
