require "test_helper"

class ArSerializerTest < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::ArSerializer::VERSION
  end

  def test_field
    post = Post.first
    assert_equal(
      { title: post.title, body: post.body },
      ArSerializer.serialize(post, [:title, :body])
    )
  end

  def test_field_specify_modes
    post = Post.first
    expected = { title: post.title }
    queries = [
      :title,
      [:title],
      { attributes: :title },
      { attributes: [:title] }
    ]
    queries.each do |query|
      assert_equal expected, ArSerializer.serialize(post, query)
    end
  end

  def test_children
    user = Post.first.user
    expected = {
      name: user.name,
      posts: user.posts.map { |p| { title: p.title } }
    }
    assert_equal expected, ArSerializer.serialize(user, [:name, posts: :title])
  end

  def test_context
    star = Star.first
    user = star.user
    post = star.comment.post
    expected = {
      comments: post.comments.map do |c|
        { current_user_stars: c.stars.where(user: user).map { |s| { id: s.id } } }
      end
    }
    data = ArSerializer.serialize(
      post,
      { comments: { current_user_stars: :id } },
      context: { current_user: user }
    )
    assert_equal expected, data
  end

end
