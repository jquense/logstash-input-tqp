# # encoding: utf-8
# require "logstash/devutils/rspec/spec_helper"
# require "logstash/devutils/rspec/shared_examples"
# require "logstash/inputs/tqp"
# require "logstash/errors"
# require "logstash/event"
# require "logstash/json"
# require "aws-sdk"
# require "ostruct"

# describe LogStash::Inputs::TQP do

#   let(:queue_name) { "my-poller" }
#   let(:queue_url) { "https://sqs.test.local/#{queue_name}" }
#   let(:config) do
#     {
#       "region" => "us-east-1",
#       "access_key_id" =>  "123",
#       "secret_access_key" =>  "secret",
#       "queue_name" =>  :queue_name,
#       "prefix" => 'my-service',
#       "topics" => ['topic--1', 'topic--2']
#     }
#   end

#   let(:input) { LogStash::Inputs::TQP.new(config) }
#   # let(:decoded_message) { { "bonjour" => "awesome" }  }
#   # let(:encoded_message)  { double("sqs_message", :body => LogStash::Json::dump(decoded_message)) }

#   subject { input }

#   let(:mock_sqs) {
#    sqs = Aws::SQS::Client.new({ :stub_responses => true })
#    sqs.stub_responses(:get_queue_url, {queue_url: queue_url})
#    sqs.stub_responses(:get_queue_attributes, {attributes: {"QueueArn" => 'aws::sqs:::coolthing'}})
#    sqs
#   }

#   context "valid credentials" do
#     let(:queue) { [] }

#     it "doesn't raise an error with valid credentials" do
#       expect(Aws::SQS::Client).to receive(:new).and_return(mock_sqs)
#       # expect(mock_sqs).to receive(:get_queue_url).with(queue_name: queue_name).and_return(queue_url: 'hi')
#       mock_sqs

#       # puts 'hi', mock_sqs.get_queue_url(queue_name: queue_name )
#       subject.register
#       # expect { subject.register }.not_to raise_error
#     end

#     # context "when interrupting the plugin" do
#     #   before do
#     #     expect(Aws::SQS::Client).to receive(:new).and_return(mock_sqs)
#     #     expect(mock_sqs).to receive(:get_queue_url).with({ :queue_name => queue_name }).and_return({:queue_url => queue_url })
#     #     expect(subject).to receive(:poller).and_return(mock_sqs).at_least(:once)

#     #     # We have to make sure we create a bunch of events
#     #     # so we actually really try to stop the plugin.

#     #     #
#     #     # rspec's `and_yield` allow you to define a fix amount of possible
#     #     # yielded values and doesn't allow you to create infinite loop.
#     #     # And since we are actually creating thread we need to make sure
#     #     # we have enough work to keep the thread working until we kill it..
#     #     #
#     #     # I haven't found a way to make it rspec friendly
#     #     mock_sqs.instance_eval do
#     #       def poll(polling_options = {})
#     #         loop do
#     #           yield [OpenStruct.new(:body => LogStash::Json::dump({ "message" => "hello world"}))], OpenStruct.new
#     #         end
#     #       end
#     #     end
#     #   end

#     #   it_behaves_like "an interruptible input plugin"
#     # end

#     # context "enrich event" do
#     #   let(:event) { LogStash::Event.new }

#     #   let(:message_id) { "123" }
#     #   let(:md5_of_body) { "dr strange" }
#     #   let(:sent_timestamp) { LogStash::Timestamp.new }
#     #   let(:epoch_timestamp) { (sent_timestamp.utc.to_f * 1000).to_i }

#     #   let(:id_field) { "my_id_field" }
#     #   let(:md5_field) { "my_md5_field" }
#     #   let(:sent_timestamp_field) { "my_sent_timestamp_field" }

#     #   let(:message) do
#     #     double("message", :message_id => message_id, :md5_of_body => md5_of_body, :attributes => { LogStash::Inputs::TQP::SENT_TIMESTAMP  => epoch_timestamp } )

#     #   end

#     #   subject { input.add_sqs_data(event, message) }

#     #   context "when the option is specified" do
#     #     let(:config) do
#     #       {
#     #         "region" => "us-east-1",
#     #         "access_key_id" => "123",
#     #         "secret_access_key" => "secret",
#     #         "queue" => queue_name,
#     #         "id_field" => id_field,
#     #         "md5_field" => md5_field,
#     #         "sent_timestamp_field" => sent_timestamp_field
#     #       }
#     #     end

#     #     it "add the `message_id`" do
#     #       expect(subject.get(id_field)).to eq(message_id)
#     #     end

#     #     it "add the `md5_of_body`" do
#     #       expect(subject.get(md5_field)).to eq(md5_of_body)
#     #     end

#     #     it "add the `sent_timestamp`" do
#     #       expect(subject.get(sent_timestamp_field).to_i).to eq(sent_timestamp.to_i)
#     #     end
#     #   end

#     #   context "when the option isn't specified" do
#     #     it "doesnt add the `message_id`" do
#     #       expect(subject).not_to include(id_field)
#     #     end

#     #     it "doesnt add the `md5_of_body`" do
#     #       expect(subject).not_to include(md5_field)
#     #     end

#     #     it "doesnt add the `sent_timestamp`" do
#     #       expect(subject).not_to include(sent_timestamp_field)
#     #     end
#     #   end
#     # end

#     # context "when decoding body" do
#     #   subject { LogStash::Inputs::TQP::new(config.merge({ "codec" => "json" })) }

#     #   it "uses the specified codec" do
#     #     subject.handle_message(encoded_message, queue)
#     #     expect(queue.pop.get("bonjour")).to eq(decoded_message["bonjour"])
#     #   end
#     # end

#     # context "receiving messages" do

#     #   before do
#     #     expect(subject).to receive(:poller).and_return(mock_sqs).at_least(:once)
#     #   end

#     #   it "creates logstash event" do
#     #     expect(mock_sqs).to receive(:poll).with(anything()).and_yield([encoded_message], double("stats"))
#     #     subject.run(queue)
#     #     expect(queue.pop.get("bonjour")).to eq(decoded_message["bonjour"])
#     #   end

#     #   context 'can create multiple events' do
#     #     require "logstash/codecs/json_lines"
#     #     let(:config) { super().merge({ "codec" => "json_lines" }) }
#     #     let(:first_message) { { "sequence" => "first" } }
#     #     let(:second_message) { { "sequence" => "second" } }
#     #     let(:encoded_message)  { double("sqs_message", :body => "#{LogStash::Json::dump(first_message)}\n#{LogStash::Json::dump(second_message)}\n") }

#     #     it 'creates multiple events' do
#     #       expect(mock_sqs).to receive(:poll).with(anything()).and_yield([encoded_message], double("stats"))
#     #       subject.run(queue)
#     #       events = queue.map{ |e|e.get('sequence')}
#     #       expect(events).to match_array([first_message['sequence'], second_message['sequence']])
#     #     end
#     #   end
#     # end

#   end
# end
