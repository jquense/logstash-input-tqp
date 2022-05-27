# encoding: utf-8
require "spec_helper"
require "logstash/inputs/tqp"
require "logstash/event"
require "logstash/json"
require "aws-sdk"
require_relative "../support/helpers"
require "thread"

Thread.abort_on_exception = true

describe "LogStash::Inputs::TQP integration" do
  let(:decoded_message) { { "drstrange" => "is-he-really-that-strange" } }
  let(:encoded_message) { LogStash::Json.dump(decoded_message) }
  let(:queue) { Queue.new }
  let(:prefix) { "jq" }
  let(:input) { 
    puts options
    LogStash::Inputs::TQP.new(options) 
  }

  context "with invalid credentials" do
    let(:options) do
      {
        "queue_name" => 'test-queue-1',
        "access_key_id" => "bad_access",
        "secret_access_key" => "bad_secret_key",
        "region" => ENV["AWS_REGION"],
        "topics": []
      }
    end

    subject { input }

    it "raises a Configuration error if the credentials are bad" do
      expect { subject.register }.to raise_error(LogStash::ConfigurationError)
    end
  end

  context "with valid credentials" do
    let(:options) do
      {
        "queue_name" => 'test-queue-1',
        "prefix" => prefix,
        "topics" => ['studies--updated'],
        "access_key_id" => ENV['AWS_ACCESS_KEY_ID'],
        "secret_access_key" => ENV['AWS_SECRET_ACCESS_KEY'],
        "region" => ENV["AWS_REGION"]
      }
    end

    before :each do
      input.register

      @server = Thread.new { input.run(queue) }
    end

    after do
      @server.kill
    end

    subject { 
      push_sns_event("#{prefix}--studies--updated", {"foo" => "bar"})
      queue.pop 
    }

    it "creates logstash events" do
      puts subject.to_json()

      expect(subject.get('[@metadata][topic]')).to eq('studies--updated')
      expect(subject.get('foo')).to eq('bar')
    end
  end
end