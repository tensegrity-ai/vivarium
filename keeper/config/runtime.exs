import Config

if sprites_token = System.get_env("SPRITES_TOKEN") do
  config :keeper, sprites_token: sprites_token
end
