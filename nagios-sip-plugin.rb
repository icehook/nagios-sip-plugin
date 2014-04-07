#!/usr/bin/env ruby

#     Copyright (C) 2010  Iñaki Baz Castillo <ibc@aliax.net>
#
#     This program is free software; you can redistribute it and/or modify
#     it under the terms of the GNU General Public License as published by
#     the Free Software Foundation; either version 2 of the License, or
#     (at your option) any later version.
#
#     This program is distributed in the hope that it will be useful,
#     but WITHOUT ANY WARRANTY; without even the implied warranty of
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#     GNU General Public License for more details.
#
#     You should have received a copy of the GNU General Public License
#     along with this program; if not, write to the Free Software
#     Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA


require "socket"
require "timeout"
require "openssl"


module NagiosSipPlugin

  EMPTY_LINE = "\r\n"
  RESPONSE_FIRST_LINE = /^SIP\/2\.0 \d{3} [^\n]*/i

  # Custom errors.
  class TransportError < StandardError ; end
  class ConnectTimeout < StandardError ; end
  class RequestTimeout < StandardError ; end
  class ResponseTimeout < StandardError ; end
  class NonExpectedStatusCode < StandardError ; end
  class WrongResponse < StandardError ; end


  class Utils

    def self.random_string(length=6, chars="abcdefghjkmnpqrstuvwxyz0123456789")
      string = ''
      length.downto(1) { |i| string << chars[rand(chars.length - 1)] }
      string
    end

    def self.generate_tag()
      random_string(8)
    end

    def self.generate_branch()
      'z9hG4bK' + random_string(8)
    end

    def self.generate_callid()
      random_string(10)
    end

    def self.generate_cseq()
      rand(999)
    end

  end  # class Utils


  class Request

    def initialize(options = {})
      @server_address = options[:server_address]
      @server_port = options[:server_port]
      @transport = options[:transport]
      @local_ip = options[:local_ip] || get_local_ip()
      @local_port = options[:local_port]
      @from_uri = options[:from_uri]
      @ruri = options[:ruri]
      @request = get_request()
      @expected_status_codes = options[:expected_status_codes]
      @timeout = options[:timeout]
      @ca_path = options[:ca_path]
      @verify_tls = options[:verify_tls]
      @debug = options[:debug]
    end

    def get_local_ip
      orig, Socket.do_not_reverse_lookup = Socket.do_not_reverse_lookup, true
      UDPSocket.open do |s|
        begin
          s.connect @server_address, @server_port
        rescue SocketError => e
          raise TransportError, "Couldn't get the server address '#{@server_address}' (#{e.class}: #{e.message})"
        rescue => e
          raise TransportError, "Couldn't get local IP (#{e.class}: #{e.message})"
        end
        s.addr.last
      end
    end
    private :get_local_ip

    def connect
      begin
        case @transport
        when "udp"
          @io = UDPSocket.new
          Timeout::timeout(@timeout) {
            @io.bind(@local_ip, @local_port)
            @io.connect(@server_address, @server_port)
          }
        when "tcp"
          Timeout::timeout(@timeout) {
            @io = TCPSocket.new(@server_address, @server_port, @local_ip)
          }
        when "tls"
          Timeout::timeout(@timeout) {
            sock = TCPSocket.new(@server_address, @server_port, @local_ip)
            ssl_context = OpenSSL::SSL::SSLContext.new
            if @verify_tls
              ssl_context.verify_mode = OpenSSL::SSL::VERIFY_PEER
              ssl_context.ca_path =  @ca_path
            else
              ssl_context.verify_mode = OpenSSL::SSL::VERIFY_NONE
            end
            ssl_context.ssl_version = :TLSv1

            @io = OpenSSL::SSL::SSLSocket.new(sock, ssl_context)
            @io.sync_close = true
            @io.connect
          }
        end
      rescue Timeout::Error => e
        raise ConnectTimeout, "Timeout when connecting the server via #{@transport.upcase} (#{e.class}: #{e.message})"
      rescue => e
        raise TransportError, "Couldn't create the #{@transport.upcase} socket (#{e.class}: #{e.message})"
      end
    end

    def debug(message)
      puts "-- Debug Information: "
      message.each { |line| puts line.chomp }
    end # def debug

    private :connect

    def send
      if ! connect
        return false
      end
      begin
        Timeout::timeout(@timeout) {
          if @transport == "tls"
            @io.syswrite(@request)
          else
            @io.send(@request,0)
          end
        }
      rescue Timeout::Error => e
        raise RequestTimeout, "Timeout sending the request via #{@transport.upcase} (#{e.class}: #{e.message}"
      rescue => e
        raise TransportError, "Couldn't send the request via #{@transport.upcase} (#{e.class}: #{e.message}"
      end
    end

    def receive
      response = Array.new
      status_codes = Array.new
      begin
        @expected_status_codes.empty? ? expected_number_of_responses = 1 : expected_number_of_responses = @expected_status_codes.length
        number_of_responses = 0
        Timeout::timeout(@timeout) {
          while response << @io.gets
            number_of_responses += 1 if response.last == EMPTY_LINE
            status_codes << response.last.split(" ")[1] if response.last =~ RESPONSE_FIRST_LINE
            break if number_of_responses == expected_number_of_responses
          end
        }
      rescue Timeout::Error => e
        raise ResponseTimeout, "Timeout receiving the response via #{@transport.upcase} (#{e.class}: #{e.message})"
      rescue => e
        raise TransportError, "Couldn't receive the response via #{@transport.upcase} (#{e.class}: #{e.message})"
      end
      if response.first !~ RESPONSE_FIRST_LINE
        raise WrongResponse, "Wrong response first line received: \"#{response.first.gsub(/[\n\r]/,'')}\""
      end

      debug(response) if @debug

      codes = Hash.new
      @expected_status_codes.each_index { |index| codes.store(@expected_status_codes[index], status_codes[index]) }
      if codes.empty?
        log_ok "status code = " + status_codes.first
      else
        codes.each do |expected, actual|
          if expected == actual or expected.nil?
            log_ok "status code = " + actual
          else
            log_warning "Received a #{actual} but #{expected} was required"
          end
        end
      end

      #@expected_status_codes.each do |exp_code|
      #  unless status_codes.include?(exp_code) or exp_code.empty?
      #    raise NonExpectedStatusCode, "Received a #{status_codes} but #{exp_code} was required"
      #  end
      #  return status_codes
      #end

    end  # def receive

  end  # class Request


  class OptionsRequest < Request

    attr_reader :request

    def get_request
      headers = <<-END_HEADERS
        OPTIONS #{@ruri} SIP/2.0
        Via: SIP/2.0/#{@transport.upcase} #{@local_ip}#{":#{@local_port}" if @local_port != 0};rport;branch=#{Utils.generate_branch}
        Max-Forwards: 5
        To: <#{@ruri}>
        From: <#{@from_uri}>;tag=#{Utils.generate_tag}
        Call-ID: #{Utils.generate_callid}@#{@local_ip}
        CSeq: #{Utils.generate_cseq} OPTIONS
        Content-Length: 0
      END_HEADERS
      headers.gsub!(/^[\s\t]*/,"")
      headers.gsub!(/\n/,"\r\n")
      return headers + "\r\n"
    end

  end  # class OptionsRequest

  class InviteRequest < Request

    attr_reader :request

    def get_request
      headers = <<-END_HEADERS
        INVITE #{@ruri} SIP/2.0
        Via: SIP/2.0/#{@transport.upcase} #{@local_ip}#{":#{@local_port}" if @local_port != 0};rport;branch=#{Utils.generate_branch}
        Max-Forwards: 5
        To: <#{@ruri}>
        From: <#{@from_uri}>;tag=#{Utils.generate_tag}
        Call-ID: #{Utils.generate_callid}@#{@local_ip}
        CSeq: #{Utils.generate_cseq} INVITE
        Content-Length: 0
      END_HEADERS
      headers.gsub!(/^[\s\t]*/,"")
      headers.gsub!(/\n/,"\r\n")
      return headers + "\r\n"
    end

  end  # class InviteRequest

end  # module NagiosSipPlugin


def show_help
  puts <<-END_HELP

Usage mode:    nagios-sip-plugin.rb [OPTIONS]

  OPTIONS:
    -t (tls|tcp|udp) :    Protocol to use (default 'udp').
    -s SERVER_IP     :    IP or domain of the server (required).
    -p SERVER_PORT   :    Port of the server (default '5060').
    -lp LOCAL_PORT   :    Local port from which UDP request will be sent. Just valid for SIP UDP (default random).
    -r REQUEST_URI   :    Request URI (default 'sip:ping@SERVER_IP:SERVER_PORT').
    -f FROM_URI      :    From URI (default 'sip:nagios@SERVER_IP').
    -c SIP_CODE(s)   :    Expected status code (i.e: '200'). For multiple codes use comma delimited list. (i.e: '100,200'). If null then any code is valid.
    -T SECONDS       :    Timeout in seconds (default '2').
    -vt              :    Verify server's TLS certificate when using SIP TLS (default false).
    -ca CA_PATH      :    Directory with public PEM files for validating server's TLS certificate (default '/etc/ssl/certs/').
    -m REQUEST_METHOD:    The request method INVITE or OPTIONS (default OPTIONS).
    -D               :    Full response debug Information (default false).

  Homepage:
    https://github.com/ibc/nagios-sip-plugin

END_HELP
end

def suggest_help
  puts "\nGet help by running:    ruby nagios-sip-plugin.rb -h\n"
end

def log_ok(text)
  $stdout.puts "OK:#{text}"
end

def log_warning(text)
  $stdout.puts "WARNING:#{text}"
end

def log_critical(text)
  $stdout.puts "CRITICAL:#{text}"
  exit 2
end

def log_unknown(text)
  $stdout.puts "UNKNOWN:#{text}"
  exit 3
end



### Run the script.

include NagiosSipPlugin

# Asking for help?
if (ARGV[0] == "-h" || ARGV[0] == "--help")
  show_help
  exit
end

args = ARGV.join(" ")

transport = args[/-t ([^\s]*)/,1] || "udp"
server_address = args[/-s ([^\s]*)/,1] || nil
server_port = args[/-p ([^\s]*)/,1] || 5060
server_port = server_port.to_i
local_port = args[/-lp ([^\s]*)/,1] || 0
local_port = local_port.to_i
ruri = args[/-r ([^\s]*)/,1] || "sip:ping@#{server_address}"
ruri = "#{ruri}:#{server_port}" if server_port
from_uri = args[/-f ([^\s]*)/,1] ||"sip:nagios@#{server_address}"
eps = args[/-c ([^\s]*)/,1] || ""
timeout = args[/-T ([^\s]*)/,1] || 2
timeout = timeout.to_i
verify_tls = args =~ /-vt/ ? true : false
ca_path = args[/-ca ([^\s]*)/,1] || "/etc/ssl/certs/"
request_method = (args[/-m ([^\s]*)/,1] || "OPTIONS").upcase
debug = args =~ /-D/ ? true : false

# Check parameters.
log_unknown "transport protocol (-t) must be 'tls', 'udp', or 'tcp'"  unless transport =~ /^(tls|udp|tcp)$/
log_unknown "server address (-s) is required"  unless server_address
if eps =~ /^([123456][0-9]{2},?)+$/ or eps.empty?
  expected_status_codes = eps.split(",")
else
  log_unknown "expected status code (-c) must be [123456]XX"
end
log_unknown "timeout (-T) must be greater than 0"  unless timeout > 0
log_unknown "request_method (-m) must be OPTIONS or INVITE"  unless %w(OPTIONS INVITE)


begin
  options = {
    :server_address => server_address,
    :server_port => server_port,
    :local_port => local_port,
    :transport => transport,
    :ruri => ruri,
    :from_uri => from_uri,
    :expected_status_codes => expected_status_codes,
    :timeout => timeout,
    :verify_tls => verify_tls,
    :ca_path => ca_path,
    :debug => debug
  }

  request = if request_method == 'OPTIONS'
    OptionsRequest.new options
  elsif request_method == 'INVITE'
    InviteRequest.new options
  end

  request.send
  request.receive

rescue NonExpectedStatusCode => e
  log_warning e.message
rescue TransportError, ConnectTimeout, RequestTimeout, ResponseTimeout, WrongResponse => e
  log_critical e.message
end
