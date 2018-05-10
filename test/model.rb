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
end

class Post < ActiveRecord::Base
  belongs_to :user
  has_many :comments
  serializer_field :id, :title, :body, :user, :comments
  serializer_field :user_only_name, association: :user, only: :name
  serializer_field(:user_except_posts, except: :posts) { user }
  serializer_field :created_at, namespace: :aaa
  serializer_field :cmnts, association: :comments
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
