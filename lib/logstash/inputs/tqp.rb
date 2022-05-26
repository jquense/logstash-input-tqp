# encoding: utf-8
#
require 'json'
require "logstash/inputs/threadable"
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


def create_queue_raw(sqs_client, queue_name, attributes, tags)
  sqs_resource = Aws::SQS::Resource.new(client: sqs_client)

  return sqs_resource.create_queue(
      queue_name: name, 
      attributes: attributes, 
      tags: tags,
  )

rescue Aws::SQS::Errors::QueueNameExists
  sqs_resource = Aws::SQS::Resource.new(client: sqs_client)

  queue_url = sqs_client.get_queue_url(queue_name: name).queue_url

  existing_tags = sqs_client.list_queue_tags(queue_url: queue_url).tags

  tags_to_remove = existing_tags.keys - tags.keys

  sqs_client.tag_queue(queue_url: queue_url, tags: tags)

  if tags_to_remove
      sqs_client.untag_queue(queue_url: queue_url, tag_keys: tags_to_remove)
  end

  # Run create again to make sure everything matches.
  return sqs_resource.create_queue(
      queue_name: name, 
      attributes: attributes, 
      tags: tags,
  )
end


def create_queue(sqs_client, queue_name, tags, **kwargs) 

  dead_letter_queue = _create_queue_raw(
      sqs_client,
      "#{queue_name}-dead-letter",
      {"MessageRetentionPeriod": 1209600},  # maximum (14 days)
      {"dlq": "true", **tags},
  )
  dead_letter_queue_arn = dead_letter_queue.attributes["QueueArn"]

  redrive_policy_kwargs = kwargs.delete("RedrivePolicy") or {}

  return create_queue_raw(
      queue_name: name, 
      attributes: {
        RedrivePolicy: {
            maxReceiveCoun: 5,
            **redrive_policy_kwargs ,
            deadLetterTargetArn: dead_letter_queue_arn,
        },
        **kwargs,
      }, 
      tags: tags,
  )
end


# Pull events from an Amazon Web Services Simple Queue Service (SQS) queue.
#
# SQS is a simple, scalable queue system that is part of the
# Amazon Web Services suite of tools.
#
# Although SQS is similar to other queuing systems like AMQP, it
# uses a custom API and requires that you have an AWS account.
# See http://aws.amazon.com/sqs/ for more details on how SQS works,
# what the pricing schedule looks like and how to setup a queue.
#
# To use this plugin, you *must*:
#
#  * Have an AWS account
#  * Setup an SQS queue
#  * Create an identify that has access to consume messages from the queue.
#
# The "consumer" identity must have the following permissions on the queue:
#
#  * `sqs:ChangeMessageVisibility`
#  * `sqs:ChangeMessageVisibilityBatch`
#  * `sqs:DeleteMessage`
#  * `sqs:DeleteMessageBatch`
#  * `sqs:GetQueueAttributes`
#  * `sqs:GetQueueUrl`
#  * `sqs:ListQueues`
#  * `sqs:ReceiveMessage`
#
# Typically, you should setup an IAM policy, create a user and apply the IAM policy to the user.
# A sample policy is as follows:
# [source,json]
#     {
#       "Statement": [
#         {
#           "Action": [
#             "sqs:ChangeMessageVisibility",
#             "sqs:ChangeMessageVisibilityBatch",
#             "sqs:GetQueueAttributes",
#             "sqs:GetQueueUrl",
#             "sqs:ListQueues",
#             "sqs:SendMessage",
#             "sqs:SendMessageBatch"
#           ],
#           "Effect": "Allow",
#           "Resource": [
#             "arn:aws:sqs:us-east-1:123456789012:Logstash"
#           ]
#         }
#       ]
#     }
#
# See http://aws.amazon.com/iam/ for more details on setting up AWS identities.
#
class LogStash::Inputs::TQP < LogStash::Inputs::Threadable
  include LogStash::PluginMixins::AwsConfig::V2

  MAX_TIME_BEFORE_GIVING_UP = 60
  MAX_MESSAGES_TO_FETCH = 10 # Between 1-10 in the AWS-SDK doc
  SENT_TIMESTAMP = "SentTimestamp"
  SQS_ATTRIBUTES = [SENT_TIMESTAMP]
  BACKOFF_SLEEP_TIME = 1
  BACKOFF_FACTOR = 2
  DEFAULT_POLLING_FREQUENCY = 20

  config_name "tqp"

  default :codec, "json"

  config :additional_settings, :validate => :hash, :default => {}

  config :prefix, :validate => :string
  config :topics, :validate => :string, :list => true

  # Polling frequency, default is 20 seconds
  config :polling_frequency, :validate => :number, :default => DEFAULT_POLLING_FREQUENCY

  attr_reader :poller

  def register
    require "aws-sdk"
    @logger.info("Registering SQS input", 
      queue: @queue, 
      queue_owner_aws_account_id: @queue_owner_aws_account_id
    )

    setup_queue
  end

  def setup_queue
    sqs_client = Aws::SQS::Client.new()
    
    @queue = create_queue(sqs_client, "#{prefix}--#{queue_name}" )

    sqs_client.top

    poller = Aws::SQS::QueuePoller.new(@queue.url, client: sqs_client)
    poller.before_request { |stats| throw :stop_polling if stop? }

    @poller = poller
  rescue Aws::SQS::Errors::ServiceError, Seahorse::Client::NetworkingError => e
    @logger.error("Cannot establish connection to Amazon SQS", exception_details(e))
    raise LogStash::ConfigurationError, "Verify the SQS queue name and your credentials"
  end

  def subscribe_to_topics(sqs_client)
    sns_client = Aws::SNS::Resource.new()

    queue_arn = @queue.attributes["QueueArn"]

    topic_arns = []

    :topics.each do |topic|
      topic = "#{topic[0]}--#{topic[1]}" if topic.kind_of?(Array)


      topic = sns.create_topic(name: "#{:prefix}--#{topic}")
      topic.subscribe(protocol: "sqs", endpoint: queue_arn)

      topic_arns.push(topic.arn)
    end

    queue.set_attributes(
      attributes: {
        Policy: {
          Version: "2012-10-17", 
          Statement: [
              {
                Sid: "sns",
                Effect: "Allow",
                Principal: {AWS: "*"},
                Action: "SQS:SendMessage",
                Resource: queue_arn,
                Condition: {ArnEquals: {aws:SourceArn: topic_arns}},
            }
          ]
        }
      }
    )

  end 

  def polling_options
    { 
      :max_number_of_messages => MAX_MESSAGES_TO_FETCH,
      :attribute_names => SQS_ATTRIBUTES,
      :wait_time_seconds => @polling_frequency
    }
  end

  def add_sns_data(self, body, event):
    topic = body["TopicArn"].split(":")[-1]

    topic = topic.slice!("#{:prefix}--") if :prefix

    message = body.delete("Message")

    event.set('[@metadata][topic]', topic)
    
    message.each do |key, value| 
      event.set(key, value)
    end
  end 

  def handle_message(message, output_queue)
    @codec.decode(message.body) do |event|
      add_sqs_data(event, message)
      decorate(event)
      output_queue << event
    end
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
    details = { :queue => @queue, :exception => e.class, :message => e.message }
    details[:code] = e.code if e.is_a?(Aws::SQS::Errors::ServiceError) && e.code
    details[:cause] = e.original_error if e.respond_to?(:original_error) && e.original_error # Seahorse::Client::NetworkingError
    details[:sleep_time] = sleep_time if sleep_time
    details[:backtrace] = e.backtrace if @logger.debug?
    details
  end

end # class LogStash::Inputs::TQP
