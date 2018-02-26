require 'ar_serializer/version'
require 'ar_serializer/serializer'
require 'ar_serializer/field'
require 'active_record'

module ArSerializer
  extend ActiveSupport::Concern

  module ClassMethods
    def _serializer_field_info
      @_serializer_field_info ||= {}
    end

    def serializer_field(*names, count_of: nil, includes: nil, preload: nil, overwrite: true, &data_block)
      names.each do |name|
        key = name.to_s
        next if !overwrite && _serializer_field_info.key?(key)
        _serializer_field_info[key] = Field.create(
          self,
          name,
          count_of: count_of,
          includes: includes,
          preload: preload,
          &data_block
        )
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
