require 'ar_serializer/error'

class ArSerializer::Field
  attr_reader :includes, :preloaders, :data_block
  def initialize includes: nil, preloaders: [], data_block:
    @includes = includes
    @preloaders = preloaders
    @data_block = data_block
  end

  def self.count_field(klass, association_name)
    preloader = lambda do |models|
      klass.joins(association_name).where(id: models.map(&:id)).group(:id).count
    end
    data_block = lambda do |preloaded, _context, _params|
      preloaded[id] || 0
    end
    new preloaders: [preloader], data_block: data_block
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

  def self.create(klass, name, count_of:, includes:, preload:, &data_block)
    if count_of
      if includes || preload || data_block
        raise ArgumentError, 'includes, preload block cannot be used with count_of'
      end
      count_field klass, count_of
    elsif klass.reflect_on_association(name) && !includes && !preload && !data_block
      association_field klass, name
    else
      custom_field klass, name, includes: includes, preload: preload, &data_block
    end
  end

  def self.custom_field(klass, name, includes:, preload:, &data_block)
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
    includes ||= name if klass.reflect_on_association name
    raise ArgumentError, 'datablock needed if preloaders are present' if !preloaders.empty? && !data_block
    new(
      includes: includes,
      preloaders: preloaders,
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
    raise ArSerializer::InvalidQuery, "unpermitted order key: #{key}" unless klass.has_attribute?(key) && klass._serializer_field_info(key)
    raise ArSerializer::InvalidQuery, "invalid order mode: #{mode.inspect}" unless [:asc, :desc, 'asc', 'desc'].include? mode
    [key.to_sym, mode.to_sym]
  end

  def self.association_field(klass, name)
    preloader = lambda do |models, _context, params|
      preload_association klass, models, name, params
    end
    data_block = lambda do |preloaded, _context, _params|
      preloaded ? preloaded[id] || [] : send(name)
    end
    new preloaders: [preloader], data_block: data_block
  end

  def self.sanintize_safe_condition klass, condition
    return unless condition.is_a? Hash
    validate_value = lambda do |value|
      next true if [nil, true, false].include? value
      next true if [String, Numeric, Symbol, Range].any? { |k| value.is_a? k }
      value.is_a?(Array) && value.all?(&validate_value)
    end
    attributes = Set.new klass.attribute_names
    condition.select do |key, value|
      attributes.include?(key.to_s) &&
        klass._serializer_field_info(key) &&
        validate_value.call(value)
    end.presence
  end

  def self.preload_association(klass, models, name, params)
    if params
      limit = params[:limit]&.to_i
      order = params[:order]
    end
    order_key, order_mode = parse_order klass.reflect_on_association(name).klass, order
    if params && params[:condition]
      ref = klass.reflect_on_association name
      condition = sanintize_safe_condition ref.klass, params[:condition]
      raise 'not implemented' if ref.join_keys.foreign_key.to_s != 'id'
      join_condition = { ref.join_keys.key => models.map(&:id) }
      records = ref.klass.where(join_condition)
      records = records.instance_exec(&ref.scope) if ref.scope
      records = records.where(condition)
    end
    if limit && top_n_loader_available?
      order_option = { limit: limit, order: { order_key => order_mode } }
      if condition
        condition_sql = records.to_sql.scan(/WHERE (.+)/).first
        raise 'cannot extract where sql' unless condition_sql
        return TopNLoader.load_groups ref.klass, ref.join_keys.key, models.map(&:id), **order_option, condition: condition_sql
      else
        return TopNLoader.load_associations klass, models.map(&:id), name, order_option
      end
    end
    if condition
      grouped_records = records.group_by(&ref.join_keys.key.to_sym)
      return grouped_records if limit.nil? && order.nil?
    else
      ActiveRecord::Associations::Preloader.new.preload models, name
      return if limit.nil? && order.nil?
      grouped_records = models.map { |model| [model.id, model.send(name)] }.to_h
    end
    grouped_records.transform_values do |records|
      records_nonnils, records_nils = records.partition(&order_key)
      records = records_nils.sort_by(&:id) + records_nonnils.sort_by { |r| [r[order_key], r.id] }
      records.reverse! if order_mode == :desc
      limit ? records.take(limit) : records
    end.to_h
  end
end
