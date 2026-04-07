import Config

if sprites_token = System.get_env("SPRITES_TOKEN") do
  config :keeper, sprites_token: sprites_token
end

if gallery_url = System.get_env("GALLERY_URL") do
  config :keeper, gallery_url: gallery_url
end

if gallery_token = System.get_env("GALLERY_TOKEN") do
  config :keeper, gallery_token: gallery_token
end
