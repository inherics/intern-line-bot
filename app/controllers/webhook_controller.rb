require 'line/bot'
require 'search.rb'

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
            text: Search.sample("笑い")
          }
          
          client.reply_message(event['replyToken'], message)
        when Line::Bot::Event::MessageType::Image, Line::Bot::Event::MessageType::Video
          response = client.get_message_content(event.message['id'])
          tf = Tempfile.open("content")
          tf.write(response.body)
        when Line::Bot::Event::MessageType::Location
          
          # 各情報を取得
          location = current_location_params(event)
          stores = search_near_store(location)
          message = template_message(stores)

          client.reply_message(event['replyToken'], message)
        end
      end
    }
    head :ok
  end


  private
    MAXIMUM_AMOUNT_MESSAGE_NUMBER = 8
    SEARCH_STORE_RADIUS = 500
    # 緯度・経度・周囲の距離(メートル）・店の種類（今回は「レストラン」）から周囲のお店を検索するAPI
    LOCATION_URL_API = "https://maps.googleapis.com/maps/api/place/nearbysearch/json?"
    # photo_referenceを使って、そのお店の画像を取得するAPI
    STORE_URL_API = "https://maps.googleapis.com/maps/api/place/photo?"
    # 緯度・経度からGoogleMapを表示するAPI
    GOOGLE_MAP_API = "https://maps.google.com./maps?"
    
    # LINEで送った現在地から、住所・緯度・経度を取得
    def current_location_params(event)
      {
        address: event.message['address'],
        latitude: event.message['latitude'],
        longitude: event.message['longitude']
      }
    end


    # 現在地から周囲のレストランの情報を取得
    def search_near_store(location)
      uri = URI.parse(LOCATION_URL_API)
      uri.query = URI.encode_www_form({ location: "#{location[:latitude]},#{location[:longitude]}", radius: SEARCH_STORE_RADIUS, types: "restaurant", language: "ja", key: "#{ENV["KEY"]}" })  
      response = Net::HTTP.get_response(uri)
      values = JSON.parse(response.body).deep_symbolize_keys

      # storesに周囲のお店の、name(お店の名前), photo_reference(お店の画像を取得するための参照情報), rating(GoogleMap上でのお店の評価),緯度・経度を代入
      stores = values[:results].each_with_object([]) do |value, store| 
        store << {
          name: value[:name],
          photo_reference: value[:photos][0][:photo_reference],
          rating: value[:rating],
          latitude: value[:geometry][:location][:lat],
          longitude: value[:geometry][:location][:lng],
        }
      end

      # storesをrating(お店の評価点)の高い順にソートして返す
      stores.sort_by!{|store| store[:rating]}.reverse 
    end


    # お店の写真のURLを取得
    def photo_url(store)
      uri = URI.parse(STORE_URL_API)
      uri.query = URI.encode_www_form({ maxwidth: 400, photoreference: "#{store}", key: "#{ENV["KEY"]}" })
      response = Net::HTTP.get_response(uri)
      values = Nokogiri::HTML.parse(response.body)

      # 解析したレスポンスがHTML形式だったので、a(アンカー)の中身を取得して返すプログラムを作成
      return values.css("a").attribute('href').value
    end


    # LINEでお店情報を返信する際の、テンプレートの返信型
    def template_message(stores)
      message = 
      {
        "type": "template",
        "altText": "周辺のお店の食べログ🍽",
        "template": {
            "type": "carousel",
            "columns": [],
            "imageAspectRatio": "rectangle",
            "imageSize": "cover"
        }
      }

      stores.each_with_index do |store, index|
        uri = URI.parse(GOOGLE_MAP_API)
        uri.query = URI.encode_www_form({ q: "#{store[:latitude]},#{store[:longitude]}" })
        
        message[:template][:columns].push(
          {
            "thumbnailImageUrl": photo_url(store[:photo_reference]),
            "imageBackgroundColor": "#FFFFFF",
            "title": store[:name],
            "text": "⭐️ #{store[:rating]}",
            "defaultAction": {
                "type": "uri",
                "label": "場所を表示する",
                "uri": uri
            },
            "actions": [
                {
                    "type": "uri",
                    "label": "場所を表示する",
                    "uri": uri
                }
            ]
          }
        )

        break if index > MAXIMUM_AMOUNT_MESSAGE_NUMBER
      end

      return message
    end

    def text_response(text)
      case text
      when '腹減った' || 'お腹すいた' || '空腹' || '腹ぺこ' || 'ひもじい'
        response = 'お腹が空いていると力が出ませんね…。現在地を送信してくださると、周辺のオススメのお店を紹介しますよ！'
      else
        response = '現在地を送信してください。周囲のオススメのお店を紹介しますよ！'
      end
    end

end
