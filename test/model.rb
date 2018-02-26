require 'active_record'
ActiveRecord::Base.include ArSerializer

class User < ActiveRecord::Base
  has_many :posts
  serializer_field :id, :name, :posts
  serializer_field(:foo) { :foo1 }
  serializer_field(:foo, namespace: :aaa) { :foo2 }
  serializer_field(:bar, namespace: [:aaa, :bbb]) { :bar }
  serializer_field(:foobar, namespace: :bbb) { :foobar }
end

class Post < ActiveRecord::Base
  belongs_to :user
  has_many :comments
  serializer_field :id, :title, :body, :user, :comments
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

  serializer_field :current_user_stars, preload: -> (comments, context) {
    Star.where(comment_id: comments.map(&:id), user_id: context[:current_user].id).group_by(&:comment_id)
  } do |preloadeds, _context|
    preloadeds[id] || []
  end
end

class Star < ActiveRecord::Base
  belongs_to :user
  belongs_to :comment
  serializer_field :id, :user
end
