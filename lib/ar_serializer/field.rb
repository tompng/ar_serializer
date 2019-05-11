require 'ar_serializer/error'

class ArSerializer::Field
  attr_reader :includes, :preloaders, :data_block, :only, :except, :order_column
  def initialize includes: nil, preloaders: [], data_block:, only: nil, except: nil, order_column: nil, type: nil, params_type: nil
    @includes = includes
    @preloaders = preloaders
    @only = only && [*only].map(&:to_s)
    @except = except && [*except].map(&:to_s)
    @data_block = data_block
    @order_column = order_column
    @type = type
    @params_type = params_type
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
    return @params_type if @params_type
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
    keys = attributes.keys.map(&:to_s) - ['*']
    return unless (@only && (keys - @only).present?) || (@except && (keys & @except).present?)
    invalid_keys = [*(@only && keys - @only), *(@except && keys & @except)].uniq
    raise ArSerializer::InvalidQuery, "unpermitted attribute: #{invalid_keys}"
  end

  def self.count_field(klass, association_name)
    preloader = lambda do |models|
      klass.joins(association_name).where(id: models.map(&:id)).group(:id).count
    end
    data_block = lambda do |preloaded, _context, _params|
      preloaded[id] || 0
    end
    new preloaders: [preloader], data_block: data_block, type: :int
  end

  def self.top_n_loader_available?
    return @top_n_loader_available unless @top_n_loader_available.nil?
    @top_n_loader_available = begin
      require 'top_n_loader'
      true
    rescue LoadError
      nil
    end
  end

  def self.type_from_column_type(klass, name)
    type = type_from_attribute_type klass, name.to_s
    return :any if type.nil?
    klass.column_for_attribute(name).null ? [*type, nil] : type
  end

  def self.type_from_attribute_type(klass, name)
    attr_type = klass.attribute_types[name]
    if attr_type.is_a?(ActiveRecord::Enum::EnumType) && klass.respond_to?(name.pluralize)
      values = klass.send(name.pluralize).keys.compact
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
      json: :string,
      binary: :string,
      time: :string,
      date: :string,
      datetime: :string
    }[attr_type.type]
  end

  def self.create(klass, name, type: nil, params_type: nil, count_of: nil, includes: nil, preload: nil, only: nil, except: nil, order_column: nil, &data_block)
    if count_of
      if includes || preload || data_block || only || except
        raise ArgumentError, 'includes, preload block cannot be used with count_of'
      end
      return count_field klass, count_of
    end
    underscore_name = name.to_s.underscore
    association = klass.reflect_on_association underscore_name if klass.respond_to? :reflect_on_association
    if association
      if association.collection?
        type ||= -> { [association.klass] }
      elsif (association.belongs_to? && association.options[:optional] == true) || (association.has_one? && association.options[:required] != true)
        type ||= -> { [association.klass, nil] }
      else
        type ||= -> { association.klass }
      end
      return association_field klass, underscore_name, only: only, except: except, type: type, collection: association.collection? if !includes && !preload && !data_block && !params_type
    end
    type ||= lambda do
      if klass.respond_to? :column_for_attribute
        type_from_column_type klass, underscore_name
      elsif klass.respond_to? :attribute_types
        type_from_attribute_type(klass, underscore_name) || :any
      else
        :any
      end
    end
    custom_field klass, underscore_name, includes: includes, preload: preload, only: only, except: except, order_column: order_column, type: type, params_type: params_type, &data_block
  end

  def self.custom_field(klass, name, includes:, preload:, only:, except:, order_column:, type:, params_type:, &data_block)
    if preload
      preloaders = Array(preload).map do |preloader|
        next preloader if preloader.is_a? Proc
        unless klass._custom_preloaders.has_key?(preloader)
          raise ArgumentError, "preloader not found: #{preloader}"
        end
        klass._custom_preloaders[preloader]
      end
    else
      preloaders = []
      includes ||= name if klass.respond_to?(:reflect_on_association) && klass.reflect_on_association(name)
    end
    data_block ||= ->(preloaded, _context, _params) { preloaded[id] } if preloaders.size == 1
    raise ArgumentError, 'data_block needed if multiple preloaders are present' if !preloaders.empty? && data_block.nil?
    new(
      includes: includes, preloaders: preloaders, only: only, except: except, order_column: order_column, type: type, params_type: params_type,
      data_block: data_block || ->(_context, _params) { send name }
    )
  end

  def self.parse_order(klass, order)
    key, mode = begin
      case order
      when Hash
        raise ArSerializer::InvalidQuery, 'invalid order' unless order.size == 1
        order.first
      when Symbol, 'asc', 'desc'
        [klass.primary_key, order]
      when NilClass
        [klass.primary_key, :asc]
      end
    end
    info = klass._serializer_field_info(key)
    key = info&.order_column || key.to_s.underscore
    raise ArSerializer::InvalidQuery, "unpermitted order key: #{key}" unless klass.has_attribute?(key) && info
    raise ArSerializer::InvalidQuery, "invalid order mode: #{mode.inspect}" unless [:asc, :desc, 'asc', 'desc'].include? mode
    [key.to_sym, mode.to_sym]
  end

  def self.association_field(klass, name, only:, except:, type:, collection:)
    if collection
      preloader = lambda do |models, _context, limit: nil, order: nil, **_option|
        preload_association klass, models, name, limit: limit, order: order
      end
      params_type = { limit?: :int, order?: [{ :* => %w[asc desc] }, 'asc', 'desc'] }
    else
      preloader = lambda do |models, _context, _params|
        preload_association klass, models, name
      end
    end
    data_block = lambda do |preloaded, _context, _params|
      preloaded ? preloaded[id] || [] : send(name)
    end
    new preloaders: [preloader], data_block: data_block, only: only, except: except, type: type, params_type: params_type
  end

  def self.preload_association(klass, models, name, limit: nil, order: nil)
    limit = limit&.to_i
    order_key, order_mode = parse_order klass.reflect_on_association(name).klass, order
    if limit && top_n_loader_available?
      return TopNLoader.load_associations klass, models.map(&:id), name, limit: limit, order: { order_key => order_mode }
    end
    ActiveRecord::Associations::Preloader.new.preload models, name
    return if limit.nil? && order.nil?
    models.map do |model|
      records_nonnils, records_nils = model.send(name).partition(&order_key)
      records = records_nils.sort_by(&:id) + records_nonnils.sort_by { |r| [r[order_key], r.id] }
      records.reverse! if order_mode == :desc
      [model.id, limit ? records.take(limit) : records]
    end.to_h
  end
end
