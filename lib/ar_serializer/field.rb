require 'ar_serializer/error'

class ArSerializer::Field
  attr_reader :includes, :preloaders, :data_block, :only, :except, :order_column
  def initialize includes: nil, preloaders: [], data_block:, only: nil, except: nil, order_column: nil, type: nil
    @includes = includes
    @preloaders = preloaders
    @only = only && [*only].map(&:to_s)
    @except = except && [*except].map(&:to_s)
    @data_block = data_block
    @order_column = order_column
    @type = type
  end

  def type
    @type.is_a?(Proc) ? @type.call : @type
  end

  def arguments
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
      if %i[opt req].include? ftype
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
    arguments[any] = false if any
    arguments
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
    column = klass.column_for_attribute name
    type = type_from_attribute_type klass, name.to_s
    if type.nil? || column.null
      type
    else
      :"#{type}!"
    end
  end

  def self.type_from_attribute_type(klass, name)
    attr_type = klass.attribute_types[name]
    if attr_type.is_a?(ActiveRecord::Enum::EnumType) && respond_to?(name.pluralize)
      classes = send(name.pluralize).keys.map(&:class).compact.uniq
      return if classes.empty?
      return :boolean if ([TrueClass, FalseClass] - classes).empty?
      return :string if ([String, Symbol] - classes).empty?
      return :int if classes == [Integer]
      return :float if classes.all? { |k| k < Numeric }
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

  def self.create(klass, name, type: nil, count_of: nil, includes: nil, preload: nil, only: nil, except: nil, order_column: nil, &data_block)
    if count_of
      if includes || preload || data_block || only || except || type
        raise ArgumentError, 'includes, preload block cannot be used with count_of'
      end
      return count_field klass, count_of
    end
    association = klass.reflect_on_association name if klass.respond_to? :reflect_on_association
    if association
      type ||= -> { association.collection? ? [association.klass] : association.klass }
      return association_field klass, name, only: only, except: except, type: type if !includes && !preload && !data_block
    end
    type ||= lambda do
      if klass.respond_to? :column_for_attribute
        type_from_column_type klass, name
      elsif klass.respond_to? :attribute_types
        type_from_attribute_type klass, name.to_s
      end
    end
    custom_field klass, name, includes: includes, preload: preload, only: only, except: except, order_column: order_column, type: type, &data_block
  end

  def self.custom_field(klass, name, includes:, preload:, only:, except:, order_column:, type: , &data_block)
    if preload
      preloaders = Array(preload).map do |preloader|
        next preloader if preloader.is_a? Proc
        unless klass._custom_preloaders.has_key?(preloader)
          raise ArgumentError, "preloader not found: #{preloader}"
        end
        klass._custom_preloaders[preloader]
      end
    end
    preloaders ||= []
    includes ||= name if klass.respond_to?(:reflect_on_association) && klass.reflect_on_association(name)
    data_block ||= ->(preloaded, _context, _params) { preloaded[id] } if preloaders.size == 1
    raise ArgumentError, 'data_block needed if multiple preloaders are present' if !preloaders.empty? && data_block.nil?
    new(
      includes: includes, preloaders: preloaders, only: only, except: except, order_column: order_column, type: type,
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
    key = info&.order_column || key
    raise ArSerializer::InvalidQuery, "unpermitted order key: #{key}" unless klass.has_attribute?(key) && info
    raise ArSerializer::InvalidQuery, "invalid order mode: #{mode.inspect}" unless [:asc, :desc, 'asc', 'desc'].include? mode
    [key.to_sym, mode.to_sym]
  end

  def self.association_field(klass, name, only:, except:, type:)
    preloader = lambda do |models, _context, limit: nil, order: nil, **_option|
      preload_association klass, models, name, limit: limit, order: order
    end
    data_block = lambda do |preloaded, _context, _params|
      preloaded ? preloaded[id] || [] : send(name)
    end
    new preloaders: [preloader], data_block: data_block, only: only, except: except, type: type
  end

  def self.preload_association(klass, models, name, limit:, order:)
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
