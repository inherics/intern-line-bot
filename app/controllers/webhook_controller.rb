require 'line/bot'

class WebhookController < ApplicationController
  protect_from_forgery except: [:callback] # CSRF対策無効化


  def client
    @client ||= Line::Bot::Client.new { |config|
      config.channel_secret = ENV["LINE_CHANNEL_SECRET"]
      config.channel_token = ENV["LINE_CHANNEL_TOKEN"]
    }
  end

  def callback
    body = request.body.read

    signature = request.env['HTTP_X_LINE_SIGNATURE']
    unless client.validate_signature(body, signature)
      head 470
    end

    events = client.parse_events_from(body)
    events.each { |event|

      case event
      when Line::Bot::Event::Message
        case event.type
        when Line::Bot::Event::MessageType::Text
          message = 
          {
            type: 'text',
            text: event.message['text']
          }
          
          client.reply_message(event['replyToken'], message)
        when Line::Bot::Event::MessageType::Image, Line::Bot::Event::MessageType::Video
          response = client.get_message_content(event.message['id'])
          tf = Tempfile.open("content")
          tf.write(response.body)
        when Line::Bot::Event::MessageType::Location
          
          location = get_current_location(event)

          stores = search_near_store(location)

          message = template_message(stores)

          client.reply_message(event['replyToken'], message)
        end
      end
    }
    head :ok
  end


  # LINEで送った現在地から、住所・緯度・経度を取得
  def get_current_location(event)
    {
      "address" => event.message['address'],
      "latitude" => event.message['latitude'],
      "longitude" => event.message['longitude']
    }
  end


  # 現在地から周囲のレストランの情報を取得
  def search_near_store(location)

    # 緯度・経度・周囲の距離・店の種類（今回は「レストラン」）から周囲のお店を検索するAPI
    location_api_url = "https://maps.googleapis.com/maps/api/place/nearbysearch/json?location=#{location["latitude"]},#{location["longitude"]}&radius=500&types=restaurant&language=ja&key=#{ENV["KEY"]}"
    uri = URI.parse(location_api_url)
    response = Net::HTTP.get_response(uri)
    values = JSON.parse(response.body)

    # storesに周囲のお店の、name(お店の名前), photo_reference(お店の画像を取得するための参照情報), rating(GoogleMap上でのお店の評価)を代入
    stores = []
    values["results"].each do |value|
        store = Hash.new { |h,k| h[k] = {} }
        store["name"] = value["name"]
        store["photo_reference"] = value["photos"][0]["photo_reference"] if value["photos"]
        store["rating"] = value["rating"]

        stores.push(store)
    end

    # storesをrating(お店の評価点)の高い順にソートして返す
    stores = stores.sort{|a,b| a['rating'].to_f <=> b['rating'].to_f}.reverse
  end


  # お店の写真のURLを取得
  def get_photo_url(store)
    # photo_referenceを使って、そのお店の画像を取得するAPI
    store_api_url = "https://maps.googleapis.com/maps/api/place/photo?maxwidth=400&photoreference=#{store}&key=#{ENV["KEY"]}"
    uri = URI.parse(store_api_url)
    response = Net::HTTP.get_response(uri)
    values = Nokogiri::HTML.parse(response.body)

    # 解析したレスポンスがHTML形式だったので、a(アンカー)の中身を取得して返すプログラムを作成
    return values.css("a").attribute('href').value
  end

  # LINEでお店情報を返信する際の、テンプレートの返信型
  def template_message(stores)

    # LINEの返信には配列の中にハッシュがある構造が必要なので作成
    # 5つ以上返信することが出来ないので、5.times doを使用
    message = Array.new
    5.times do |i|
        message.push(
            {
                "type": "template",
                "altText": "This is a buttons template",
                "template": {
                    "type": "buttons",
                    "thumbnailImageUrl": get_photo_url(stores[i]["photo_reference"]),
                    "imageAspectRatio": "rectangle",
                    "imageSize": "cover",
                    "imageBackgroundColor": "#FFFFFF",
                    "title": stores[i]["name"],
                    "text": "⭐️ #{stores[i]["rating"]}",
                    "defaultAction": {
                        "type": "uri",
                        "label": "View detail",
                        "uri": "http://example.com/page/123"
                    },
                    "actions": [
                        {
                        "type": "uri",
                        "label": "View detail",
                        "uri": "http://example.com/page/123"
                        }
                    ]
                }
            }
        )
    end

    return message
  end
end
