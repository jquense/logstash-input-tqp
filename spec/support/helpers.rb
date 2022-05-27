require 'logstash/json'

# encoding: utf-8
def push_sqs_event(message)
  client = Aws::SQS::Client.new
  queue_url = client.get_queue_url(queue_name: ENV['SQS_QUEUE_NAME'])

  client.send_message({ queue_url: queue_url.queue_url, message_body: message })
end

def push_sns_event(topic, message)
  resource = Aws::SNS::Resource.new

  puts "sending message #{topic}"

  topic = resource.create_topic(name: topic)
  topic.publish(message: LogStash::Json.dump(message))
end
