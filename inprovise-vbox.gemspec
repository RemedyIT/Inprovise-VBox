require File.join(File.dirname(__FILE__), 'lib/inprovise/vbox/version')

Gem::Specification.new do |gem|
  gem.authors       = ["Johnny Willemsen"]
  gem.email         = ["jwillemsen@remedy.nl"]
  gem.description   = %q{VBox script extension for Inprovise}
  gem.summary       = %q{Simple, easy and intuitive virtual machine provisioning}
  gem.homepage      = "https://github.com/RemedyIT/Inprovise-VBox"

  gem.files         = `git ls-files`.split($\)
  gem.executables   = gem.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})
  gem.name          = "inprovise-vbox"
  gem.require_paths = ["lib"]
  gem.version       = Inprovise::VBox::VERSION
  gem.add_dependency('inprovise')
  gem.post_install_message = ''
end
