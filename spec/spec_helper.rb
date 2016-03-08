require 'simplecov'
require 'timecop'

SimpleCov.start
Timecop.safe_mode = true

$LOAD_PATH.unshift File.expand_path('../../lib', __FILE__)
require 'pressure'
