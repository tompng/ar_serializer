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

  def self.preload_association(klass, models, name, params)
    if params
      limit = params[:limit]&.to_i
      order = params[:order]
    end
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
