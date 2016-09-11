# VBox Script tests for Inprovise
#
# Author::    Martin Corino
# License::   Distributes under the same license as Ruby

require_relative 'test_helper'

describe Inprovise::VBox do

  after :each do
    reset_script_index!
  end

  describe Inprovise::DSL do
    it 'adds a VBox script' do
      script = Inprovise::DSL.module_eval do
        vbox 'myVbox' do
          configuration({
            :image => '/path/to/disk/image.qcow2',
            :memory => 512,
            :cpus => 1,
          })
        end
      end
      script = Inprovise::ScriptIndex.default.get('myVbox')
      script.name.must_equal 'myVbox'
    end

    it 'defines default configuration' do
      script = Inprovise::DSL.module_eval do
        vbox 'myVbox' do
        end
      end
      script.configuration.must_be_kind_of Hash
      script.configuration[:arch].must_equal 'x86_64'
      script.configuration[:memory].must_equal 1024
      script.configuration[:cpus].must_equal 1
      script.configuration[:network].must_equal :hostnet
    end
  end

end
