# encoding: utf-8
# HipChat connection
# Uses HipChat's XMPP connection

require 'xmpp4r'
require 'xmpp4r/muc/helper/simplemucclient'
require 'isis/connections/base'

class Isis::Connections::HipChat < Isis::Connections::Base

  attr_accessor :client
  attr_accessor :muc

  def initialize(config)
    load_config(config)
    create_jabber_and_mucs
  end

  def create_jabber_and_mucs
    @client = Jabber::Client.new(@config['hipchat']['jid'])
    @muc = {}
    @config['hipchat']['rooms'].each do |room|
      @muc[room] = Jabber::MUC::SimpleMUCClient.new(client)
    end
  end

  def send_jabber_presence
    @client.send(Jabber::Presence.new.set_type(:available))
  end

  def connect
    attempt = 0
    begin
      @client.connect
    rescue SocketError => e
      # The Network is down
      rest = 5*(1+Math::log(attempt += 1)) # 5, 8.5, 10.5, 12, 13, 14, ...
      puts "Network Error(#{attempt}): #{e}", "Sleeping #{"%.1f"%rest}s then rereting…"
      sleep rest
      retry
    end
    @client.auth(@config['hipchat']['password'])
    send_jabber_presence
    @join_time = Time.now
  end

  def reconnect
    kill_and_clean_up
    create_jabber_and_mucs
    connect
  end

  def kill_and_clean_up
    @client.close
  end

  def register_disconnect_callback
    @client.on_exception do |e, stream, where|
      puts "Exception! #{e.to_s}"
      self.connect  # Reconnect!
    end
  end

  def register_plugins(bot)
    @muc.each do |room,muc|
      register_plugins_internal(muc, bot)
    end
  end

  def register_plugins_internal(muc, bot)
    muc.on_message do |time, speaker, message|
      # |time| is useless - comes back blank
      # we must fend for ourselves

      # All UTF-8, All the time
      message.encode!("UTF-8")
      speaker.encode!("UTF-8")

      # always respond to commands prefixed with 'sudo '
      sudo = message.match /^sudo (.+)/
      message = sudo[1] if sudo

      puts "MESSAGE: s:#{speaker} m:#{message}"
      # ignore our own messages
      if speaker == @config['hipchat']['name'] and not sudo
        nil

      else
        bot.plugins.each do |plugin|
          begin
            response = plugin.receive_message(message, speaker, @muc.key(muc))
            unless response.nil?
              if response.respond_to?('each')
                response.each {|line| speak(muc, line)}
              else
                speak(muc, response)
              end
            end
          rescue => e
            speak muc, "ERROR: Plugin #{plugin.class.name} just crashed"
            speak muc, "Message: #{e.message}"
          end
        end
      end
    end
  end
  private :register_plugins_internal

  def join
    @muc.each do |room,muc|
      puts "Joining: #{room}/#{@config['hipchat']['name']} maxstanzas:#{@config['hipchat']['history']}"
      begin
        muc.join "#{room}/#{@config['hipchat']['name']}", @config['hipchat']['password'], :history => @config['hipchat']['history']
      rescue => e
        puts "## EXCEPTION in Hipchat join: #{e.message}"
        bot.recover_from_exception
      end
    end
  end

  # Add HTML container, create Jabber::Message
  # Or not.. because Hipchat still doesn't support html-im
  def _message(room, message)
    return Jabber::Message.new(room, message)

    text = message.respond_to?(:to_text) ? message : message.to_s
    m = Jabber::Message.new(room, text)
    m.add(message) rescue nil
    puts m.inspect
    m
  end

  def yell(message)
    @muc.each do |room,muc|
      m = _message(muc.room, message)
      muc.send m
    end
  end

  def speak(muc, message)
    m = _message(muc.room, message)
    muc.send m
  end

  def still_connected?
    @client.is_connected?
  end
end
