module TinyCallCenter
  class WebSocketChannel < Struct.new(:reporter, :socket, :command_socket_server, :user, :agent, :channel_id)
    include WebSocketUtils, ChannelRelay
    Channel = EM::Channel.new

    def initialize(reporter, socket, command_socket_server)
      self.reporter, self.socket = reporter, socket
      self.command_socket_server = command_socket_server

      socket.onopen(&method(:on_open))
      socket.onmessage(&method(:on_message))
      socket.onclose(&method(:on_close))
    end

    def on_open
      self.channel_id = Channel.subscribe{|message|
        reply(message) if can_view?(message)
      }
    end

    def on_close
      Channel.unsubscribe(channel_id)
      FSR::Log.debug "Unsubscribed listener: #{agent}"
    end

    def on_message(json)
      msg = JSON.parse(json)

      method = "got_#{msg['method']}"

      if respond_to?(method)
        send(method, msg)
      else
        FSR::Log.warn "Unknown message: %p" % [msg]
      end
    rescue JSON::ParserError => ex
      FSR::Log.error ex
    end

    def agent_listing
      sock = fsr_socket(self.command_socket_server)
      agents = sock.call_center(:agent).list.run
      sock.socket.close
      agents
    end

    def got_subscribe(msg)
      self.agent = msg['agent']
      FSR::Log.info "Subscribing listener: #{self.agent}"

      # everything regarding perms in Account
      self.user = Account.from_call_center_name(agent)
      FSR::Log.info "User #{user} subscribed"

      give_agent_listing
      give_queues
    end

    def got_status_of(msg)
      mapped = STATUS_MAPPING[msg['status']]
      agent = msg['agent']
      reporter.callcenter!{|cc| cc.set(agent, :status, mapped) }
    end

    def got_state_of(msg)
      agent = msg['agent']
      reporter.callcenter!{|cc| cc.set(agent, :state, msg['state']) }
    end

    def got_agents_of(msg)
      queue_names = [msg["queue"], msg["queues"]].flatten.compact
      sock = fsr_socket(self.command_socket_server)
      queue_names.each do |queue_name|
        tiers = sock.call_center(:tier).list(queue_name).run.select{|tier| can_view?(cc_agent: tier.agent) }
        reply method: :agents_of, args: [queue_name, tiers]
      end
    end

    def give_queues
      sock = fsr_socket(self.command_socket_server)
      queues = sock.call_center(:queue).list.run
      reply method: :queues, args: [queues]
    end

    def give_agent_listing
      agents = agent_listing
      if user.manager?
        agents.select! {|agent| user.can_view?(agent.extension) }
        FSR::Log.info "#{user} can view #{agents.size} agents"
      else
        # if somehow an agent got here, just show them themselves
        FSR::Log.info "User #{user} not a manager, showing just self"
        agents.select! {|agent| self.agent == agent.name }
      end

      servers = {}
      registrars = agents.map {|agent| agent.contact.split("@")[1] }.uniq
      registrars.each do |r|
        begin
          fsock = FSR::CommandSocket.new server: r
          servers[r] = fsock.channels(true).run
          fsock.socket.close
          fsock = nil
        rescue Errno::ECONNREFUSED => e
          FSR::Log.error "Registration Server #{r} not found"
        end
      end

      utimes = %w[last_bridge_start last_offered_call last_bridge_end last_status_change]
      agents.map!{|agent|
        agent_ext = Account.extension(agent.name)
        agent_username = Account.full_name(agent.name)
        agent_server = agent.contact.to_s.split('@')[1]
        agent_calls = servers[agent_server]

        agent_hash = agent.to_hash
        agent_hash.merge!(agent_status(agent_ext, agent_calls))
        agent_hash.merge!(extension: agent_ext, username: agent_username)

        if cr = CallRecord.last(agent.name)
          cr_at = cr.created_at
        end
        last_call_time = [
          cr_at,
          Time.at(agent_hash['last_bridge_end'].to_i),
          Date.today.to_time + (8 * 60 * 60), # 08:00
        ].compact.max
        agent_hash.merge!(last_call_time: last_call_time.rfc2822)

        utimes.each{|key| agent_hash[key] = Time.at(agent_hash[key].to_i).rfc2822 }
        WebSocketReporter::SubscribedAgents[agent_ext] ||= [agent.name]
        agent_hash
      }

      reply method: :agent_list, args: [agents]
    end

    def can_view?(message)
      return false unless agent

      self.user ||= Account.from_call_center_name(agent)
      return false unless user && user.extension

      if cc = message[:cc_agent]
        extension = Account.extension cc
        FSR::Log.debug("#{user} has user extension #{user.extension} and extension #{extension} cc is #{cc}")
        return true if cc == agent
        return user.extension == extension || user.can_view?(extension)
      end

      numbers = possible_numbers(message)
      unless numbers.size > 1
        FSR::Log.warn "%p Asking for access to crazysauce: %p" % [agent, message]
        return true
      end

      FSR::Log.debug "%p asking for access to %p" % [agent, numbers]
      return true if numbers.detect{|number| number.size == 4 && user.can_view?(number) }

      FSR::Log.debug "%p denied access to %p" % [agent, numbers]
      false
    end

    def got_calltap_too(msg)
      extension, name, tapper, uuid, phoneNumber = msg.values_at('extension', 'name', 'tapper', 'uuid', 'phoneNumber')
      if manager = Account.from_call_center_name(tapper)
        return false unless manager.manager?
        return false unless agent = Account.from_full_name(name)
        if manager.manager.authorized_to_listen?(extension, phoneNumber)
          eavesdrop(uuid, agent, manager)
        end
      end
    end

    def got_calltap(msg)
      agent, tapper = msg.values_at('agent', 'tapper').map { |a| Account.new(Account.username a) }
      return false unless agent.exists? and tapper.exists?
      return false unless tapper.manager?
      if (sock = FSR::CommandSocket.new(:server => agent.registration_server) rescue nil)
        res = sock.say("api hash select/#{agent.registration_server}-spymap/#{agent.extension}")
        if uuid = res["body"]
          eavesdrop(uuid, agent, tapper)
        end
      end
    end

    def eavesdrop(uuid, agent, tapper)
      return false unless agent.registration_server
      FSR::Log.info("Tapping #{agent.full_name} at #{agent.registration_server}: #{uuid}")
      if (sock = FSR::CommandSocket.new(:server => agent.registration_server) rescue nil)
        if eavesdrop_extension = tapper.manager.eavesdrop_extension
          cmd = sock.originate(:target => eavesdrop_extension, :endpoint => "&eavesdrop(#{uuid})")
        elsif tapper.registration_server == agent.registration_server
          cmd = sock.originate(:target => "user/#{tapper.extension}", :endpoint => "&eavesdrop(#{uuid})")
        else
          cmd = sock.originate(:target => "sofia/internal/#{tapper.extension}@#{tapper.registration_server}", :endpoint => "&eavesdrop(#{uuid})")
        end
        FSR::Log.info("Tap Command %p" % cmd.raw)
        cmd.run
      end
    end

    def got_agent_call_history(msg)
    end

    def got_agent_disposition_history(msg)
    end

    def got_agent_status_history(msg)
      FSR::Log.info "Sending status history of #{msg['agent']}"
      reply tiny_action: 'agent_status_history',
            cc_agent: msg['agent'],
            history: TCC::StatusLog.filter{|r|
              (r.agent == msg['agent']) &
              (r.created_at > (Date.today - 1)) &
              (r.created_at < (Date.today + 1))
            }.select(:new_status, :created_at).map(&:values)
    end

    def got_agent_state_history(msg)
      FSR::Log.info "Sending state history of #{msg['agent']}"
      reply tiny_action: 'agent_state_history',
            cc_agent: msg['agent'],
            history: TCC::StatusLog.filter{|r|
              (r.agent == msg['agent']) &
              (r.created_at > (Date.today - 1)) &
              (r.created_at < (Date.today + 1))
            }.select(:new_state, :created_at).map(&:values)
    end
  end
end
