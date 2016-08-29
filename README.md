
Inprovise Virtual Box
=====================

This project implements an extension for the Inprovise provisioning tool providing `vbox` scripts for installing
Libvirt based virtual machine instances.

Installation
------------

    $ gem install inprovise-vbox

Usage
-----

Add the following to (for example) your Inprovise project's `rigrc` file.

````ruby
require 'inprovise/vbox'
````

Syntax
------

````ruby
vbox 'myvm' do

    configure ({
      :name => 'MyVM',
      :image => '/remote/image/path',
      :memory => 1024,
      :cpus => 2  
    })

end
````

When applying this script for a target VM host node it will automatically create a virtual machine instance `MyVM`
on the specified host and define a new Inprovise infrastructure node if the installation was successful.

Optionally user defined `apply`, `revert` and/or `validate` blocks can be added to provide additional (custom) 
processing.
  
