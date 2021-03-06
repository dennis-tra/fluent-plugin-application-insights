require "helper"
require "fluent/plugin/out_application_insights.rb"
require_relative "mock_client.rb"

class ApplicationInsightsOutputTest < Test::Unit::TestCase
  setup do
    Fluent::Test.setup
  end

  CONFIG = %[
    instrumentation_key ikey
  ]

  def create_driver(conf = CONFIG)
    driver = Fluent::Test::Driver::Output.new(Fluent::Plugin::ApplicationInsightsOutput).configure(conf)
    driver.instance.start

    sender = MockSender.new
    queue = MockQueue.new sender
    channel = ApplicationInsights::Channel::TelemetryChannel.new nil, queue
    driver.instance.tc = ApplicationInsights::TelemetryClient.new "iKey", channel

    return driver
  end

  sub_test_case 'configure' do
    test 'invalid context tag key' do
      config = %[
        instrumentation_key ikey
        context_tag_sources invalid_tag_name:kubernetes_container_name
      ]
      assert_raise ArgumentError.new("Context tag 'invalid_tag_name' is invalid!") do
        create_driver config
      end
    end
  end

  sub_test_case 'process standard schema event' do
    setup do
      config = %[
        instrumentation_key ikey
        standard_schema true
      ]

      @d = create_driver config
    end

    test 'ikey and timestamps are added if empty' do
      time = event_time("2011-01-02 13:14:15 UTC")
      @d.run(default_tag: 'test', shutdown: false) do
        @d.feed(time, {"name" => "telemetry name", "data" => { "baseType" => "RequestData", "baseData" => {} }})
      end

      envelope = @d.instance.tc.channel.queue[0]
      assert_equal "ikey", envelope.i_key
      assert_equal "2011-01-02T13:14:15.0000000Z", envelope.time
    end

    test 'event missing required properties is treated as non standard schema' do
      time = event_time("2011-01-02 13:14:15 UTC")
      @d.instance.log.level = "debug"
      @d.run(default_tag: 'test', shutdown: false) do
          @d.feed(time, {})
          @d.feed(time, {"data" => 2})
          @d.feed(time, {"data" => {}})
          @d.feed(time, {"data" => {"someprop" => "value"}})
          @d.feed(time, {"data" => {"baseType" => "type"}})
          @d.feed(time, {"data" => {"baseData" => "data"}})
      end

      logs = @d.instance.log.out.logs
      assert_equal 6, logs.length
      assert_true logs.all?{ |log| log.include?("The event does not meet the standard schema of Application Insights output. Missing data, baseType or baseData property.") }
    end

    test 'event of standard schema will fill in the name property if it is empty' do
      config = %[
        instrumentation_key 000-000-000
        standard_schema true
      ]
      d = create_driver config

      time = event_time("2011-01-02 13:14:15 UTC")
      d.run(default_tag: 'test', shutdown: false) do
        d.feed(time, {
          "data" => { "baseType" => "RequestData", "baseData" => {} }
        })
      end

      envelope = d.instance.tc.channel.queue[0]
      assert_equal "Microsoft.ApplicationInsights.000000000.Request", envelope.name
    end

    test 'event of standard schema will fill in the name property if it is empty and instrumentation key is empty' do
      config = %[
        instrumentation_key ""
        standard_schema true
      ]
      d = create_driver config

      time = event_time("2011-01-02 13:14:15 UTC")
      d.run(default_tag: 'test', shutdown: false) do
        d.feed(time, {
          "data" => { "baseType" => "RequestData", "baseData" => {} }
        })
      end

      envelope = d.instance.tc.channel.queue[0]
      assert_equal "Microsoft.ApplicationInsights.Request", envelope.name
    end

    test 'event with unknown data type is treated as non standard schema' do
      time = event_time("2011-01-02 13:14:15 UTC")
      @d.instance.log.level = "debug"
      @d.run(default_tag: 'test', shutdown: false) do
          @d.feed(time, {"name" => "telemetry name", "data" => {"baseType" => "unknown", "baseData" => {}}})
      end

      logs = @d.instance.log.out.logs
      assert_true logs.length > 0
      assert_true logs.all?{ |log| log.include?("Unknown telemetry type unknown") }
    end

    test 'extra properties are not lost after processing' do
      time = event_time("2011-01-02 13:14:15 UTC")
      @d.run(default_tag: 'test', shutdown: false) do
        @d.feed(time, {"name" => "telemetry name", "data" => { "baseType" => "RequestData", "baseData" => {} }, "kubernetes" => { "pod_name" => "frontend" }})
      end

      envelope = @d.instance.tc.channel.queue[0]
      assert_equal({ "kubernetes" => "{\"pod_name\":\"frontend\"}" }, envelope.data["baseData"]["properties"])
    end
  end

  sub_test_case 'set context on standard schema event' do
    test 'context tag sources is empty' do
      config = %[
        instrumentation_key ikey
        standard_schema true
        context_tag_sources {}
      ]
      d = create_driver config

      time = event_time("2011-01-02 13:14:15 UTC")
      d.run(default_tag: 'test', shutdown: false) do
        d.feed(time, {
          "name" => "telemetry name",
          "data" => { "baseType" => "RequestData", "baseData" => {} },
          "kubernetes_container_name" => "frontend"
        })
      end

      envelope = d.instance.tc.channel.queue[0]
      assert_true envelope.tags.length == 0
    end

    test 'context tag sources does not exist on record' do
      config = %[
        instrumentation_key ikey
        standard_schema true
        context_tag_sources ai.cloud.role:kubernetes_container_name
      ]
      d = create_driver config

      time = event_time("2011-01-02 13:14:15 UTC")
      d.run(default_tag: 'test', shutdown: false) do
        d.feed(time, {
          "name" => "telemetry name",
          "data" => { "baseType" => "RequestData", "baseData" => {} }
        })
      end

      envelope = d.instance.tc.channel.queue[0]
      assert_not_nil envelope.tags
      assert_nil envelope.tags["ai.cloud.role"]
    end

    test 'context is updated according to context tag keys' do
      config = %[
        instrumentation_key ikey
        standard_schema true
        context_tag_sources ai.cloud.role:kubernetes_container_name
      ]
      d = create_driver config

      time = event_time("2011-01-02 13:14:15 UTC")
      d.run(default_tag: 'test', shutdown: false) do
        d.feed(time, {
          "name" => "telemetry name",
          "data" => { "baseType" => "RequestData", "baseData" => {} },
          "kubernetes_container_name" => "frontend",
          "other_prop" => "prop value"
        })
      end

      envelope = d.instance.tc.channel.queue[0]
      assert_not_nil envelope.tags
      assert_equal "frontend", envelope.tags["ai.cloud.role"]

      extra_properties = {
        "kubernetes_container_name" => "frontend",
        "other_prop" => "prop value"
      }
      assert_equal extra_properties, envelope.data["baseData"]["properties"]
    end

    test 'context tag source is nested property path' do
      config = %[
        instrumentation_key ikey
        standard_schema true
        context_tag_sources {
          "ai.cloud.role": "$.kubernetes.container_name",
          "ai.cloud.roleInstance": "$.kubernetes.not_exist"
        }
      ]
      d = create_driver config

      time = event_time("2011-01-02 13:14:15 UTC")
      d.run(default_tag: 'test', shutdown: false) do
        d.feed(time, {
          "name" => "telemetry name",
          "data" => { "baseType" => "RequestData", "baseData" => {} },
          "kubernetes" => {
            "container_name" => "frontend",
            "container_id" => "c42c557e1615511dd3a3cb1d6e8f14984464bb0f"
          }
        })
      end

      envelope = d.instance.tc.channel.queue[0]
      assert_not_nil envelope.tags
      assert_equal "frontend", envelope.tags["ai.cloud.role"]
      assert_nil envelope.tags["ai.cloud.roleInstance"]
    end

    test 'multiple context tag keys' do
      config = %[
        instrumentation_key ikey
        standard_schema true
        context_tag_sources {
          "ai.cloud.role": "kubernetes_container_name",
          "ai.cloud.roleInstance": "$.docker.container_id"
        }
      ]
      d = create_driver config

      time = event_time("2011-01-02 13:14:15 UTC")
      d.run(default_tag: 'test', shutdown: false) do
        d.feed(time, {
          "name" => "telemetry name",
          "data" => { "baseType" => "RequestData", "baseData" => {} },
          "docker" => {
            "container_id" => "c42c557e1615511dd3a3cb1d6e8f14984464bb0f"
          },
          "kubernetes_container_name" => "frontend"
        })
      end

      envelope = d.instance.tc.channel.queue[0]
      assert_not_nil envelope.tags
      assert_equal "frontend", envelope.tags["ai.cloud.role"]
      assert_equal "c42c557e1615511dd3a3cb1d6e8f14984464bb0f", envelope.tags["ai.cloud.roleInstance"]
    end
  end

  sub_test_case 'process non standard schema event' do
    test 'empty message' do
      d = create_driver

      time = event_time("2011-01-02 13:14:15 UTC")
      d.run(default_tag: 'test', shutdown: false) do
        d.feed(time, {"prop" => "value"})
      end

      assert_equal 1, d.instance.tc.channel.queue.queue.length
      envelope = d.instance.tc.channel.queue[0]
      assert_equal "Null", envelope.data.base_data.message
      assert_equal envelope.data.base_data.properties, {"prop" => "value"}
    end

    test 'custom timestamp take precedence over fluentd timestamp' do
      config = %[
        instrumentation_key ikey
        time_property time
      ]
      d = create_driver config

      time = event_time("2011-01-02 13:14:15 UTC")
      d.run(default_tag: 'test', shutdown: false) do
        d.feed(time, {"time" => "2010-10-01"})
      end

      envelope = d.instance.tc.channel.queue[0]
      assert_equal "2010-10-01", envelope.time
    end

    test 'custom timestamp format is not ensured to be valid' do
      config = %[
        instrumentation_key ikey
        time_property time
      ]
      d = create_driver config

      time = event_time("2011-01-02 13:14:15 UTC")
      d.run(default_tag: 'test', shutdown: false) do
        d.feed(time, {"time" => "custom time"})
      end

      envelope = d.instance.tc.channel.queue[0]
      assert_equal "custom time", envelope.time
    end

    test 'timestamp is in iso8601 format' do
      d = create_driver

      time = event_time("2011-01-02 13:14:15 UTC")
      d.run(default_tag: 'test', shutdown: false) do
        d.feed(time, {"message" => "log message"})
      end

      envelope = d.instance.tc.channel.queue[0]
      assert_equal "2011-01-02T13:14:15.0000000Z", envelope.time
    end

    test 'custom message property' do
      config = %[
        instrumentation_key ikey
        message_property custom_message_property
      ]
      d = create_driver config

      time = event_time("2011-01-02 13:14:15 UTC")
      d.run(default_tag: 'test', shutdown: false) do
        d.feed(time, {"custom_message_property" => "custom message", "message" => "my message"})
      end

      envelope = d.instance.tc.channel.queue[0]
      assert_equal "custom message", envelope.data.base_data.message
    end

    test 'custom severity level mapping' do
      config = %[
        instrumentation_key ikey
        severity_property custom_severity_property
        severity_level_error 100
      ]
      d = create_driver config

      time = event_time("2011-01-02 13:14:15 UTC")
      d.run(default_tag: 'test', shutdown: false) do
        d.feed(time, {"custom_severity_property" => 100, "message" => "my message"})
      end

      envelope = d.instance.tc.channel.queue[0]
      assert_equal ApplicationInsights::Channel::Contracts::SeverityLevel::ERROR, envelope.data.base_data.severity_level
    end

    test 'multiple severity levels' do
      config = %[
        instrumentation_key ikey
        severity_property custom_severity_property
        severity_level_critical fatal, panic
      ]
      d = create_driver config

      time = event_time("2011-01-02 13:14:15 UTC")
      d.run(default_tag: 'test', shutdown: false) do
        d.feed(time, {"custom_severity_property" => "panic", "message" => "my message"})
      end

      d.run(default_tag: 'test', shutdown: false) do
        d.feed(time, {"custom_severity_property" => "fatal", "message" => "my message"})
      end

      d.run(default_tag: 'test', shutdown: false) do
        d.feed(time, {"custom_severity_property" => "critical", "message" => "my message"})
      end

      envelope = d.instance.tc.channel.queue[0]
      assert_equal ApplicationInsights::Channel::Contracts::SeverityLevel::CRITICAL, envelope.data.base_data.severity_level

      envelope = d.instance.tc.channel.queue[1]
      assert_equal ApplicationInsights::Channel::Contracts::SeverityLevel::CRITICAL, envelope.data.base_data.severity_level
      
      envelope = d.instance.tc.channel.queue[2]
      assert_not_equal ApplicationInsights::Channel::Contracts::SeverityLevel::CRITICAL, envelope.data.base_data.severity_level
    end

    test 'properties are stringified' do
      d = create_driver

      time = event_time("2011-01-02 13:14:15 UTC")
      d.run(default_tag: 'test', shutdown: false) do
        d.feed(time, {"prop" => {"inner_prop1" => "value1", "inner_prop2" => "value2"}})
      end

      envelope = d.instance.tc.channel.queue[0]
      assert_equal 1, envelope.data.base_data.properties.length
      assert_equal "{\"inner_prop1\":\"value1\",\"inner_prop2\":\"value2\"}", envelope.data.base_data.properties["prop"]
    end
  end

  sub_test_case 'set context on non standard schema event' do
    test 'context tag sources is empty' do
      config = %[
        instrumentation_key ikey
        context_tag_sources {}
      ]
      d = create_driver config

      time = event_time("2011-01-02 13:14:15 UTC")
      d.run(default_tag: 'test', shutdown: false) do
        d.feed(time, {
          "message" => "my message",
          "kubernetes_container_name" => "frontend"
        })
      end

      envelope = d.instance.tc.channel.queue[0]

      # The only tag is "ai.internal.sdkVersion", which is irrelevant to contaxt_tag_sources
      assert_true envelope.tags.length == 1
      assert_equal "ai.internal.sdkVersion", envelope.tags.keys[0]
      assert_equal "ikey", envelope.i_key
    end

    test 'context tag sources does not exist on record' do
      config = %[
        instrumentation_key ikey
        context_tag_sources ai.cloud.role:kubernetes_container_name
      ]
      d = create_driver config

      time = event_time("2011-01-02 13:14:15 UTC")
      d.run(default_tag: 'test', shutdown: false) do
        d.feed(time, {
          "message" => "my message"
        })
      end

      envelope = d.instance.tc.channel.queue[0]
      assert_not_nil envelope.tags
      assert_nil envelope.tags["ai.cloud.role"]
    end

    test 'context is updated according to context tag keys' do
      config = %[
        instrumentation_key ikey
        context_tag_sources ai.cloud.role:kubernetes_container_name
      ]
      d = create_driver config

      time = event_time("2011-01-02 13:14:15 UTC")
      d.run(default_tag: 'test', shutdown: false) do
        d.feed(time, {
          "message" => "my message",
          "kubernetes_container_name" => "frontend",
          "other_prop" => "prop value"
        })
      end

      envelope = d.instance.tc.channel.queue[0]
      assert_not_nil envelope.tags
      assert_equal "frontend", envelope.tags["ai.cloud.role"]
      assert_not_nil envelope.data.base_data.properties["kubernetes_container_name"]
      assert_not_nil envelope.data.base_data.properties["other_prop"]
    end

    test 'context tag source is nested property path' do
      config = %[
        instrumentation_key ikey
        context_tag_sources {
          "ai.cloud.role": "$.kubernetes.container_name",
          "ai.cloud.roleInstance": "$.kubernetes.not_exist"
        }
      ]
      d = create_driver config

      time = event_time("2011-01-02 13:14:15 UTC")
      d.run(default_tag: 'test', shutdown: false) do
        d.feed(time, {
          "name" => "telemetry name",
          "data" => { "baseType" => "RequestData", "baseData" => {} },
          "kubernetes" => {
            "container_name" => "frontend",
            "container_id" => "c42c557e1615511dd3a3cb1d6e8f14984464bb0f"
          }
        })
      end

      envelope = d.instance.tc.channel.queue[0]
      assert_not_nil envelope.tags
      assert_equal "frontend", envelope.tags["ai.cloud.role"]
      assert_nil envelope.tags["ai.cloud.roleInstance"]
    end

    test 'multiple context tag keys' do
      config = %[
        instrumentation_key ikey
        context_tag_sources {
          "ai.cloud.role": "kubernetes_container_name",
          "ai.cloud.roleInstance": "$.docker.container_id"
        }
      ]
      d = create_driver config

      time = event_time("2011-01-02 13:14:15 UTC")
      d.run(default_tag: 'test', shutdown: false) do
        d.feed(time, {
          "message" => "my message",
          "docker" => {
            "container_id" => "c42c557e1615511dd3a3cb1d6e8f14984464bb0f"
          },
          "kubernetes_container_name" => "frontend"
        })
      end

      envelope = d.instance.tc.channel.queue[0]
      assert_not_nil envelope.tags
      assert_true envelope.tags.length == 3
      assert_equal "frontend", envelope.tags["ai.cloud.role"]
      assert_equal "c42c557e1615511dd3a3cb1d6e8f14984464bb0f", envelope.tags["ai.cloud.roleInstance"]
    end
  end

  sub_test_case 'stringify_properties' do
    test 'simple data type are not stringified' do
      plugin = create_driver.instance

      record = {prop1: 1, prop2: true, prop3: "value"}
      actual = plugin.stringify_properties(record)
      expected = {prop1: 1, prop2: true, prop3: "value"}
      assert_equal expected, actual
    end

    test 'json and array property values are stringified' do
      plugin = create_driver.instance

      record = {prop1: 1, prop2: [1, 2, 3], prop3: {inner_prop: "value"}}
      actual = plugin.stringify_properties(record)
      expected = {prop1: 1, prop2: "[1,2,3]", prop3: "{\"inner_prop\":\"value\"}"}
      assert_equal expected, actual
    end

    test 'stringify complicated property value' do
      plugin = create_driver.instance

      record = {
        arr: [1, [2, [3, {inner: "value"}]]],
        obj: {
          arr: [1, {inarr: "inarr"}],
          inobj: {
            ininobj: {
              prop: "value"
            },
            num: 3.14
          }
        }
      }

      actual = plugin.stringify_properties(record)
      expected = {
        :arr=> "[1,[2,[3,{\"inner\":\"value\"}]]]",
        :obj=> "{\"arr\":[1,{\"inarr\":\"inarr\"}],\"inobj\":{\"ininobj\":{\"prop\":\"value\"},\"num\":3.14}}"
      }
      assert_equal expected, actual
    end
  end

end
