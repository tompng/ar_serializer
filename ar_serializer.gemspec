
lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'ar_serializer/version'

Gem::Specification.new do |spec|
  spec.name          = 'ar_serializer'
  spec.version       = ArSerializer::VERSION
  spec.authors       = ['tompng']
  spec.email         = ['tomoyapenguin@gmail.com']

  spec.summary       = %(ActiveRecord serializer, avoid N+1)
  spec.description   = %(ActiveRecord serializer, avoid N+1)
  spec.homepage      = "https://github.com/tompng/#{spec.name}"
  spec.license       = 'MIT'

  spec.files = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features)/})
  end
  spec.bindir = 'exe'
  spec.executables = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_dependency 'activerecord'
  spec.add_dependency 'top_n_loader'
  %w[rake sqlite3 minitest simplecov].each do |gem_name|
    spec.add_development_dependency gem_name
  end
end
