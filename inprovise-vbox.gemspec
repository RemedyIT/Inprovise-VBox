Gem::Specification.new do |gem|
  gem.authors       = ["Martin Corino"]
  gem.email         = ["mcorino@remedy.nl"]
  gem.description   = %q{VBox script extension for Inprovise}
  gem.summary       = %q{Simple, easy and intuitive virtual machine provisioning}
  gem.homepage      = ""

  gem.files         = `git ls-files`.split($\)
  gem.executables   = gem.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})
  gem.name          = "inprovise-vbox"
  gem.require_paths = ["lib"]
  gem.version       = '0.1.1'
  gem.add_dependency('inprovise')
  gem.post_install_message = ''
end
