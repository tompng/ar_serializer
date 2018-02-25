require 'ar_serializer/version'
require 'ar_serializer/serializer'
require 'active_record'

module ArSerializer
  extend ActiveSupport::Concern

  module ClassMethods
    def _serializer_field_info
      @_serializer_field_info ||= {}
    end

    def serializer_field(*names, includes: nil, preload: nil, overwrite: true, &data_block)
      if preload
        preloaders = Array(preload).map do |preloader|
          next preloader if preloader.is_a? Proc
          raise "preloader not found: #{preloader}" unless _custom_preloaders.has_key?(preloader)
          _custom_preloaders[preloader]
        end
      end
      preloaders ||= []
      names.each do |name|
        sub_includes = includes || (name if reflect_on_association(name))
        block = data_block || ->(_context, _params) { send name }
        key = name.to_s
        next if !overwrite && _serializer_field_info.key?(key)
        _serializer_field_info[key] = {
          includes: sub_includes,
          preloaders: preloaders,
          data: block
        }
      end
    end

    def _custom_preloaders
      @_custom_preloaders ||= {}
    end

    def define_preloader(name, &block)
      _custom_preloaders[name] = block
    end
  end

  def self.serialize(*args)
    Serializer.serialize(*args)
  end
end
