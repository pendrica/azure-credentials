# frozen_string_literal: true

lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |spec|
  spec.name          = 'azure-credentials'
  spec.version       = '0.1.5'
  spec.authors       = ['Stuart Preston']
  spec.email         = ['stuart@pendrica.com']
  spec.summary       = 'AzureRM credential generator'
  spec.description   = 'Utility to generate AzureRM credentials files in various formats using Azure AD user credentials.'
  spec.homepage      = 'https://github.com/pendrica/azure-credentials'
  spec.license       = 'Apache-2.0'
  spec.executables   = ['azure-credentials']
  spec.files         = Dir['LICENSE', 'README.md', 'CHANGELOG.md', 'lib/**/*', 'bin/**/*']
  spec.require_paths = ['lib']

  spec.add_dependency 'json', '~> 1.8', '>= 1.8.3'
  spec.add_dependency 'mixlib-cli', '~> 1', '= 1.5.0'

  spec.add_development_dependency 'bundler', '~> 1.7'
  spec.add_development_dependency 'rake', '~> 10.0'
  spec.add_development_dependency 'rspec', '~> 0'
  spec.add_development_dependency 'rubocop', '~> 0'
end
