require 'active_record'

class User < ActiveRecord::Base
  has_many :posts
  serializer_field :id, :name, :posts
  serializer_field(:foo, type: :string) { :foo1 }
  serializer_field(:foo, namespace: :aaa, type: :string) { :foo2 }
  serializer_field(:bar, namespace: [:aaa, :bbb], type: :string) { :bar }
  serializer_field(:foobar, namespace: :bbb, type: :string) { :foobar }
  serializer_field(:posts_only_title, includes: :posts, only: :title, type: -> { [Post] }) { posts }
  serializer_field :posts_only_body, association: :posts, only: :body
  serializer_field(:favorite_post, type: -> { FavoritePost }) { FavoritePost.new id if id.odd? }
  serializer_field(
    :posts_with_total,
    type: -> { { total: :int, list: [Post] } },
    preload: lambda do |models, _context, **params|
      [
        ArSerializer::Field.preload_association(User, models, :posts, **params),
        User.where(id: models.map(&:id)).joins(:posts).group(:id).count
      ]
    end
  ) do |(lists, totals)|
    models = lists[id]
    total = totals[id] || 0
    ArSerializer::CustomSerializable.new models do |result|
      { total: total, list: models.map(&result) }
    end
  end
end

class Post < ActiveRecord::Base
  belongs_to :user
  has_many :comments
  serializer_field :id, :title, :body, :user, :comments
  serializer_field :user_only_name, association: :user, only: :name
  serializer_field(:user_except_posts, includes: :user, except: :posts, type: User) { user }
  serializer_field :created_at, namespace: :aaa
  serializer_field :cmnts, association: :comments
  serializer_field(:modifiedAt, order_column: :updated_at, type: :string) { updated_at }
  serializer_field :createdAt
  serializer_field :Comments
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

  serializer_field :reason, type: :string
  serializer_field(
    :post,
    type: Post,
    preload: ->(fps) { Post.where(id: fps.map(&:pstid)).index_by(&:id) }
  ) do |preloaded|
    preloaded[pstid]
  end
end

class Comment < ActiveRecord::Base
  belongs_to :user
  belongs_to :post
  has_one :star
  has_many :stars
  serializer_field :id, :body, :user, :stars
  serializer_field :stars_count, count_of: :stars
  serializer_field :star

  star_count_loader = ->(comments) do
    Star.where(comment_id: comments.map(&:id)).group(:comment_id).count
  end

  serializer_field :stars_count_x5, type: :int, preload: star_count_loader do |preloaded|
    (preloaded[id] || 0) * 5
  end

  serializer_field :current_user_stars, type: -> { [Star] }, preload: lambda { |comments, context|
    stars = Star.where(comment_id: comments.map(&:id), user_id: context[:current_user].id)
    Hash.new { [] }.merge stars.group_by(&:comment_id)
  }
end

class Star < ActiveRecord::Base
  belongs_to :user
  belongs_to :comment
  serializer_field :id, :user
end
