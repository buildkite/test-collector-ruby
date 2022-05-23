module IoHelpers
  def reset_io(io)
    io.truncate(0)
    io.rewind
  end
end

RSpec.configure do |config|
  config.include IoHelpers
end
