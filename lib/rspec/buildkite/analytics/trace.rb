class RSpec::Buildkite::Analytics::Trace
  attr_accessor :example, :failure_reason, :failure_expanded
  attr_reader :id, :history

  FILE_PATH_REGEX = /^(.*?\.(rb|feature))/

  def initialize(example, history:, failure_reason: nil, failure_expanded: [])
    @id = SecureRandom.uuid
    @example = example
    @history = history
    @failure_reason = failure_reason
    @failure_expanded = failure_expanded
  end

  def result
    case example.execution_result.status
    when :passed; "passed"
    when :failed; "failed"
    when :pending; "skipped"
    end
  end

  def as_hash
    strip_invalid_utf8_chars(
      id: id,
      scope: example.example_group.metadata[:full_description],
      name: example.description,
      identifier: example.id,
      location: example.location,
      file_name: file_name,
      result: result,
      failure_reason: failure_reason,
      failure_expanded: failure_expanded,
      history: history,
    ).with_indifferent_access.compact
  end

  private

  def file_name
    @file_name ||= begin
      identifier_file_name = strip_invalid_utf8_chars(example.id)[FILE_PATH_REGEX]
      location_file_name = example.location[FILE_PATH_REGEX]

      if identifier_file_name != location_file_name
        # If the identifier and location files are not the same, we assume
        # that the test was run as part of a shared example. If this isn't the
        # case, then there's something we haven't accounted for
        if shared_example?
          # Taking the last frame in this backtrace will give us the original
          # entry point for the shared example
          shared_example_call_location[FILE_PATH_REGEX]
        else
          "Unknown"
        end
      else
        identifier_file_name
      end
    end
  end

  def shared_example?
    example.metadata[:shared_group_inclusion_backtrace].any?
  end

  def shared_example_call_location
    example.metadata[:shared_group_inclusion_backtrace].last.inclusion_location
  end

  def strip_invalid_utf8_chars(object)
    if object.is_a?(Hash)
      Hash[object.map { |key, value| [key, strip_invalid_utf8_chars(value)] }]
    elsif object.is_a?(Array)
      object.map { |value| strip_invalid_utf8_chars(value) }
    elsif object.is_a?(String)
      object.encode('UTF-8', :invalid => :replace, :undef => :replace)
    else
      object
    end
  end
end
