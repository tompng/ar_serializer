require 'ar_serializer/error'
require 'top_n_loader'

class ArSerializer::Field
  attr_reader :includes, :preloaders, :data_block, :only, :except, :scoped_access, :order_column
  def initialize klass, name, includes: nil, preloaders: [], data_block:, only: nil, except: nil, private: false, scoped_access: nil, order_column: nil, orderable: nil, type: nil, params_type: nil
    @klass = klass
    @name = name
    @includes = includes
    @preloaders = preloaders
    @only = only && [*only].map(&:to_s)
    @except = except && [*except].map(&:to_s)
    @private = private
    @scoped_access = scoped_access.nil? ? true : scoped_access
    @data_block = data_block
    @order_column = order_column
    @orderable = orderable
    @type = type
    @params_type = params_type
  end

  def orderable?
    return @orderable unless @orderable.nil?
    @orderable = @klass.has_attribute? (@order_column || @name).to_s.underscore
  end

  def private?
    @private
  end

  def type
    type = @type.is_a?(Proc) ? @type.call : @type
    splat = lambda do |t|
      case t
      when Array
        if t.size == 1 || (t.size == 2 && t.compact.size == 1)
          t.map(&splat)
        else
          t.map { |v| v.is_a?(String) ? v : splat.call(v) }
        end
      when Hash
        t.transform_values(&splat)
      else
        t
      end
    end
    splat.call type
  end

  def arguments
    return @params_type.is_a?(Proc) ? @params_type.call : @params_type if @params_type
    @preloaders.size
    @data_block.parameters
    parameters_list = [@data_block.parameters.drop(@preloaders.size + 1)]
    @preloaders.each do |preloader|
      parameters_list << preloader.parameters.drop(2)
    end
    arguments = {}
    any = false
    parameters_list.each do |parameters|
      ftype, fname = parameters.first
      if %i[opt req rest].include? ftype
        any = true unless fname.match?(/^_/)
        next
      end
      parameters.each do |type, name|
        case type
        when :keyreq
          arguments[name] ||= true
        when :key
          arguments[name] ||= false
        when :keyrest
          any = true unless name.match?(/^_/)
        when :opt, :req
          break
        end
      end
    end
    return :any if any && arguments.empty?
    arguments.map do |key, req|
      type = key.to_s.match?(/^(.+_)?id|Id$/) ? :int : :any
      name = key.to_s.underscore
      type = [type] if name.singularize.pluralize == name
      [req ? key : "#{key}?", type]
    end.to_h
  end

  def validate_attributes(attributes)
    return unless @only || @except
    keys = attributes.map(&:first).map(&:to_s) - ['*']
    return unless (@only && (keys - @only).present?) || (@except && (keys & @except).present?)
    invalid_keys = [*(@only && keys - @only), *(@except && keys & @except)].uniq
    raise ArSerializer::InvalidQuery, "unpermitted attribute: #{invalid_keys}"
  end

  def self.count_field(klass, name, association_name)
    preloader = lambda do |models|
      klass.joins(association_name).where(id: models.map(&:id)).group(:id).count
    end
    data_block = lambda do |preloaded, _context, **_params|
      preloaded[id] || 0
    end
    new klass, name, preloaders: [preloader], data_block: data_block, type: :int, orderable: false
  end

  def self.type_from_column_type(klass, name)
    type = type_from_attribute_type klass, name.to_s
    return :any if type.nil?
    klass.column_for_attribute(name).null ? [*type, nil] : type
  end

  def self.type_from_attribute_type(klass, name)
    attr_type = klass.attribute_types[name]
    if attr_type.is_a?(ActiveRecord::Enum::EnumType) && klass.respond_to?(name.pluralize)
      values = klass.__send__(name.pluralize).keys.compact
      values = values.map { |v| v.is_a?(Symbol) ? v.to_s : v }.uniq
      valid_classes = [TrueClass, FalseClass, String, Integer, Float]
      return if values.empty? || (values.map(&:class) - valid_classes).present?
      return values
    end
    {
      boolean: :boolean,
      integer: :int,
      float: :float,
      decimal: :float,
      string: :string,
      text: :string,
      json: :unknown,
      binary: :string,
      time: :string,
      date: :string,
      datetime: :string
    }[attr_type.type]
  end

  def self.create(klass, name, type: nil, params_type: nil, count_of: nil, includes: nil, preload: nil, only: nil, except: nil, private: nil, scoped_access: nil, order_column: nil, orderable: nil, &data_block)
    name = name.to_s
    if count_of
      if includes || preload || data_block || only || except || order_column || orderable || scoped_access != nil
        raise ArgumentError, 'wrong options for count_of field'
      end
      return count_field klass, name, count_of
    end
    association = klass.reflect_on_association name.underscore if klass.respond_to? :reflect_on_association
    if association
      if association.collection?
        type ||= -> { [association.klass] }
      elsif (association.belongs_to? && association.options[:optional] == true) || (association.has_one? && association.options[:required] != true)
        type ||= -> { [association.klass, nil] }
      else
        type ||= -> { association.klass }
      end
      return association_field klass, name, only: only, except: except, scoped_access: scoped_access, type: type, collection: association.collection? if !includes && !preload && !data_block && !params_type
    end
    type ||= lambda do
      if klass.respond_to? :column_for_attribute
        type_from_column_type klass, name.underscore
      elsif klass.respond_to? :attribute_types
        type_from_attribute_type(klass, name.underscore) || :any
      else
        :any
      end
    end
    custom_field klass, name, includes: includes, preload: preload, only: only, except: except, private: private, scoped_access: scoped_access, order_column: order_column, orderable: orderable, type: type, params_type: params_type, &data_block
  end

  def self.custom_field(klass, name, includes:, preload:, only:, except:, private:, scoped_access:, order_column:, orderable:, type:, params_type:, &data_block)
    underscore_name = name.underscore
    if preload
      preloaders = [*preload]
    else
      preloaders = []
      includes ||= underscore_name if klass.respond_to?(:reflect_on_association) && klass.reflect_on_association(underscore_name)
    end
    data_block ||= ->(preloaded, _context, **_params) { preloaded[id] } if preloaders.size == 1
    raise ArgumentError, 'data_block needed if multiple preloaders are present' if !preloaders.empty? && data_block.nil?
    new(
      klass,
      name,
      includes: includes, preloaders: preloaders, only: only, except: except, private: private, scoped_access: scoped_access, order_column: order_column, orderable: orderable, type: type, params_type: params_type,
      data_block: data_block || ->(_context, **_params) { __send__ underscore_name }
    )
  end

  def self.parse_order(klass, order, only: nil, except: nil)
    primary_key = klass.primary_key.to_sym
    key, mode = (
      case order
      when Hash
        raise ArSerializer::InvalidQuery, 'invalid order' unless order.size == 1
        order.first.map(&:to_sym)
      when Symbol, 'asc', 'desc'
        [primary_key, order.to_sym]
      when NilClass
        [primary_key, :asc]
      end
    )
    info = klass._serializer_field_info(key)
    order_key = (info&.order_column || key).to_s.underscore.to_sym
    raise ArSerializer::InvalidQuery, "invalid order mode: #{mode.inspect}" unless [:asc, :desc].include? mode
    raise ArSerializer::InvalidQuery, "unpermitted order key: #{key}" unless key == primary_key || (info&.orderable? && (!only || only.include?(key)) && !except&.include?(key))
    [order_key, mode]
  end

  def self.association_field(klass, name, only:, except:, scoped_access: nil, type:, collection:)
    underscore_name = name.underscore
    only = [*only] if only
    except = [*except] if except
    if collection
      preloader = lambda do |models, _context, limit: nil, order: nil, **_option|
        preload_association klass, models, underscore_name, limit: limit, order: order, only: only, except: except
      end
      params_type = -> {
        orderable_keys = klass.reflect_on_association(underscore_name).klass._serializer_orderable_field_keys
        orderable_keys &= only.map(&:to_s) if only
        orderable_keys -= except.map(&:to_s) if except
        orderable_keys |= ['id']
        orderable_keys.sort!
        modes = %w[asc desc]
        {
          limit?: :int,
          order?: orderable_keys.map { |key| { key => modes } } +  modes
        }
      }
      data_block = lambda do |preloaded, _context, **_params|
        preloaded ? preloaded[id || self] || [] : __send__(underscore_name)
      end
    else
      preloader = lambda do |models, _context, **_params|
        preload_association klass, models, underscore_name
      end
      data_block = lambda do |preloaded, _context, **_params|
        preloaded ? preloaded[id || self] : __send__(underscore_name)
      end
    end
    new klass, name, preloaders: [preloader], data_block: data_block, only: only, except: except, scoped_access: scoped_access, type: type, params_type: params_type, orderable: false
  end

  def self.preload_association(klass, models, name, limit: nil, order: nil, only: nil, except: nil)
    limit = limit&.to_i
    order_key, order_mode = parse_order klass.reflect_on_association(name).klass, order, only: only, except: except
    return TopNLoader.load_associations klass, models.map(&:id), name, limit: limit, order: { order_key => order_mode } if limit
    ActiveRecord::Associations::Preloader.new.preload models, name
    return models.map { |m| [m.id || m, m.__send__(name)] }.to_h if order.nil?
    models.map do |model|
      records_nonnils, records_nils = model.__send__(name).partition(&order_key)
      records = records_nils.sort_by(&:id) + records_nonnils.sort_by { |r| [r[order_key], r.id] }
      records.reverse! if order_mode == :desc
      [model.id || model, records]
    end.to_h
  end
end
