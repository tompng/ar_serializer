require 'ar_serializer/version'
require 'ar_serializer/serializer'
require 'ar_serializer/field'
require 'active_record'

module ArSerializer
  extend ActiveSupport::Concern

  module ClassMethods
    def _serializer_namespace(ns)
      (@_serializer_field_info ||= {})[ns] ||= {}
    end

    def _serializer_field_info(name, namespaces: nil)
      if namespaces
        Array(namespaces).each do |ns|
          field = _serializer_namespace(ns)[name.to_s]
          return field if field
        end
      end
      _serializer_namespace(nil)[name.to_s]
    end

    def serializer_field(*names, count_of: nil, includes: nil, preload: nil, namespace: nil, &data_block)
      namespaces = namespace.is_a?(Array) ? namespace : [namespace]
      namespaces.each do |ns|
        names.each do |name|
          field = Field.create self, name, count_of: count_of, includes: includes, preload: preload, &data_block
          _serializer_namespace(ns)[name.to_s] = field
        end
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
