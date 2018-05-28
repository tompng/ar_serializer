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

    def _serializer_field_info(name)
      namespaces = ArSerializer::Serializer.current_namespaces
      if namespaces
        Array(namespaces).each do |ns|
          field = _serializer_namespace(ns)[name.to_s]
          return field if field
        end
      end
      field = _serializer_namespace(nil)[name.to_s]
      if field
        field
      elsif superclass < ActiveRecord::Base
        superclass._serializer_field_info name
      end
    end

    def _serializer_field_keys
      namespaces = ArSerializer::Serializer.current_namespaces
      keys = []
      if namespaces
        Array(namespaces).each do |ns|
          keys |= _serializer_namespace(ns).keys
        end
      end
      keys |= _serializer_namespace(nil).keys
      keys |= superclass._serializer_field_keys if superclass < ActiveRecord::Base
      keys
    end

    def serializer_field(*names, association: nil, count_of: nil, includes: nil, preload: nil, namespace: nil, only: nil, except: nil, &data_block)
      namespaces = namespace.is_a?(Array) ? namespace : [namespace]
      namespaces.each do |ns|
        names.each do |name|
          field = Field.create self, association || name, count_of: count_of, includes: includes, preload: preload, only: only, except: except, &data_block
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

    def serializer_defaults(*args, &block)
      serializer_field :defaults, *args, &block
    end
  end

  def self.serialize(*args)
    Serializer.serialize(*args)
  end
end

ActiveRecord::Base.include ArSerializer
