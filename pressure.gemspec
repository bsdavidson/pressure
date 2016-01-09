# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'pressure/version'

Gem::Specification.new do |spec|
  spec.name          = 'pressure'
  spec.version       = Pressure::VERSION
  spec.authors       = ['Brian Davidson']
  spec.email         = ['bsdavidson@gmail.com']

  spec.summary       = %q(Multicast upstream data to websocket clients)
  spec.homepage      = 'https://github.com/bsdavidson/pressure'
  spec.license       = 'MIT'

  spec.files         = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features)/})
  end
  spec.bindir        = 'exe'
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_development_dependency 'bundler', '~> 1.9'
  spec.add_development_dependency 'rake', '~> 10.0'
  spec.add_development_dependency 'rspec'
  spec.add_development_dependency 'redcarpet', '~> 3.3'
  spec.add_development_dependency 'sinatra', '~> 1.4'
  spec.add_development_dependency 'yard', '~> 0.8'
end
