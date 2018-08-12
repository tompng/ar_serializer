require 'active_record'

class User < ActiveRecord::Base
  has_many :posts
  serializer_field :id, :name, :posts
  serializer_field(:foo) { :foo1 }
  serializer_field(:foo, namespace: :aaa) { :foo2 }
  serializer_field(:bar, namespace: [:aaa, :bbb]) { :bar }
  serializer_field(:foobar, namespace: :bbb) { :foobar }
  serializer_field(:posts_only_title, only: :title) { posts }
  serializer_field(:posts_only_body, only: :body) { posts }
  serializer_field(:favorite_post) { FavoritePost.new id if id.odd? }
  serializer_field(
    :posts_with_total,
    preload: lambda do |models, _context, params|
      {
        list: ArSerializer::Field.preload_association(User, models, :posts, params),
        total: User.where(id: models.map(&:id)).joins(:posts).group(:id).count
      }
    end
  ) do |preloaded|
    sub_models = preloaded[:list] ? preloaded[:list][id] : posts
    total = preloaded[:total][id] || 0
    sub_outputs = sub_models.map { {} }
    ArSerializer::CompositeValue.new(
      pairs: sub_models.zip(sub_outputs),
      output: { total: total || 0, list: sub_outputs }
    )
  end
end

class Post < ActiveRecord::Base
  belongs_to :user
  has_many :comments
  serializer_field :id, :title, :body, :user, :comments
  serializer_field :user_only_name, association: :user, only: :name
  serializer_field(:user_except_posts, except: :posts) { user }
  serializer_field :created_at, namespace: :aaa
  serializer_field :cmnts, association: :comments
  serializer_field(:updatedAt, order_column: :updated_at) { updated_at }
end

class FavoritePost
  include ArSerializer::Serializable
  def initialize(num)
    @num = num
  end

  def pstid
    @num * 7 % 13
  end

  def reason
    reasons = %w[like good nice funny]
    reasons[@num % reasons.size]
  end

  serializer_field :reason
  serializer_field(
    :post, preload: ->(fps) { Post.where(id: fps.map(&:pstid)).index_by(&:id) }
  ) do |preloaded|
    preloaded[pstid]
  end
end

class Comment < ActiveRecord::Base
  belongs_to :user
  belongs_to :post
  has_many :stars
  serializer_field :id, :body, :user, :stars
  serializer_field :stars_count, count_of: :stars

  define_preloader :star_count_loader do |comments|
    Star.where(comment_id: comments.map(&:id)).group(:comment_id).count
  end

  serializer_field :stars_count_x5, preload: :star_count_loader do |preloaded|
    (preloaded[id] || 0) * 5
  end

  serializer_field :current_user_stars, preload: lambda { |comments, context|
    stars = Star.where(comment_id: comments.map(&:id), user_id: context[:current_user].id)
    Hash.new { [] }.merge stars.group_by(&:comment_id)
  }
end

class Star < ActiveRecord::Base
  belongs_to :user
  belongs_to :comment
  serializer_field :id, :user
end
