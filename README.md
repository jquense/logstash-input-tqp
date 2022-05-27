# logstash-input-tqp plugin

This is a plugin for [Logstash](https://github.com/elastic/logstash).

It is fully free and fully open source. The license is Apache 2.0, meaning you are pretty much free to use it however you want in whatever way.

## Documentation

TQP is an an opinionated library for pub/sub over SQS and SNS

`logstash-input-tqp` is an input plugin for logstash to implements the same tqp conventions for SQS queue construction and topic subscription.

```
input {
  tqp {
    queue_name => "logstash-poller",
    topics => ["my-topic"]
    access_key_id => ENV["AWS_ACCESS_KEY_ID"],
    secret_access_key => ENV["AWS_SECRET_ACCESS_KEY"],
    region" => ENV["AWS_REGION"]
  }
}
```

The plugin will create a SQS queue (and an associated DLQ) if it doesn't exist and subscribe
to each configured topic. SNS messages are parsed from `json`, and set as the logstash event.
the topic name is also added to the event `@metadata`.
