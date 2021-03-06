p = () ->
  window.console?.debug?(arguments)

store = {
  agents: {},
  searches: {},
  stateMapping: {
    Idle: 'Wrap Up',
    Waiting: 'Ready',
  }
}

statusOrStateToClass = (prefix, str) ->
  prefix + str.toLowerCase().replace(/\W+/g, "-").replace(/^-+|-+$/g, "")

queueToClass = (queue) ->
  queue.toLowerCase().replace(/\W+/g, '_').replace(/^_+|_+$/g, "")

divmod = (num1, num2) ->
  [num1 / num2, num1 % num2]

formatInterval = (start) ->
  total   = parseInt((Date.now() - start) / 1000, 10)
  [hours, rest] = divmod(total, 60 * 60)
  [minutes, seconds] = divmod(rest, 60)
  sprintf("%02d:%02d:%02d", hours, minutes, seconds)

formatPhoneNumber = (number) ->
  return number unless number?

  if md = number.match(/^(\d+?)(\d{3})(\d{3})(\d{4})$/)
    "(#{md[2]})-#{md[3]}-#{md[4]}"
  else
    number

searchToQuery = (raw) ->
  if /^[,\s]*$/.test(raw)
    $('#agents').isotope(filter: '*')
    return false

  query = []
  for part in raw.split(/\s*,\s*/g)
    part = part.replace(/'/, '')
    query.push(":contains('#{part}')")

  return query.join(", ")

class Socket
  constructor: (@controller) ->
    @connect()

  connect: () ->
    webSocket = if "MozWebSocket" of window then MozWebSocket else WebSocket
    @ws = new webSocket(store.server)
    @reconnector = setInterval =>
      unless @connected
        @ws = new webSocket(store.server)
        @prepareWs()
    , 1000

  prepareWs: ->
    @ws.onopen = =>
      @say(method: 'subscribe', agent: store.agent)
      @connected = true

    @ws.onmessage = (message) =>
      data = JSON.parse(message.data)
      # p "onMessage", data
      @controller.dispatch(data)

    @ws.onclose = =>
      p "Closing WebSocket"
      @connected = false

    @ws.onerror = (error) =>
      p "WebSocket Error:", error

  say: (obj) ->
    # p "Socket.send", obj
    @ws.send(JSON.stringify(obj))


class Controller
  dispatch: (msg) ->
    p msg
    if method = msg.method
      @["got_#{method}"].apply(this, msg.args)
    else if action = msg.tiny_action
      store.agents[msg.cc_agent]["got_#{action}"](msg)

  got_queues: (queues) ->
    list = $('#nav-queues')
    list.html('')

    unsorted = []
    for queue in queues
      unsorted.push(queue)
    sorted = unsorted.sort (a, b) -> a.name > b.name

    for queue in sorted
      li = $('<li>')
      a = $('<a>', href: '#').text(queue.name)
      li.append(a)
      list.append(li)

  got_agent_list: (agents) ->
    p agents
    for rawAgent in agents
      agent = store.agents[rawAgent.name] || new Agent(rawAgent.name)
      agent.fillFromAgent(rawAgent)

  got_agents_of: (queue, tiers) ->
    for tier in tiers
      agent = store.agents[tier.agent] || new Agent(tier.agent)
      agent.fillFromTier(tier)
    $('#agents').isotope(filter: ".#{queueToClass(queue)}")

  got_call_start: (msg) ->
    store.agents[msg.cc_agent].got_call_start(msg)

  got_channel_hangup: (msg) ->
    store.agents[msg.cc_agent].got_channel_hangup(msg)


class Call
  constructor: (@agent, @localLeg, @remoteLeg, msg) ->
    @uuid = localLeg.uuid
    @klass = "call-#{@uuid}"
    @createDOM()
    @renderInAgent()
    @renderInDialog()
    @setTimer(new Date(Date.parse(msg.call_created)))
    @agent.addCall(this)

  createDOM: ->
    @dom = store.protoCall.clone()
    @dom.attr('id', '')
    @dom.attr('class', "#{@klass} call")
    $('.cid-number', @dom).text(formatPhoneNumber(@remoteLeg.cid_number))
    $('.cid-name', @dom).text(@remoteLeg.cid_name) unless @remoteLeg.cid_name == 'unknown'
    $('.destination', @dom).text(formatPhoneNumber(@remoteLeg.destination))
    $('.queue-name', @dom).text(@localLeg.queue)
    $('.uuid', @dom).text(@localLeg.uuid)
    $('.channel', @dom).text(@localLeg.channel)
    @dialogDOM = @dom.clone(true)

  setTimer: (@startingTime) ->
    @timer = setInterval =>
      $('.time-of-call-start', @dom).text(formatInterval(@startingTime)) if @dom
      $('.time-of-call-start', @dialogDOM).text(formatInterval(@startingTime)) if @dialogDOM
    , 1000

  hangup: (msg) ->
    @agent.startingTime = new Date(Date.now())
    @agent.removeCall(this)
    clearInterval(@timer)
    $('.more-calls', @agent.dom).text('')
    @dom.slideUp("normal", -> $(this).remove())
    @dialogDOM.remove()

  renderInAgent: ->
    $('.calls', @agent.dom).append(@dom)

  renderInDialog: ->
    $('.calls', @agent.dialog).append(@dialogDOM) if @agent.dialog?

  calltap: ->
    p "tapping #{@agent.name}: #{@agent.extension} <=> #{@remoteLeg.cid_number} (#{@localLeg.uuid}) by #{store.agent}"
    store.ws.say(
      method: 'calltap_too',
      tapper: store.agent,
      name: @agent.name,
      extension: @agent.extension,
      uuid: @localLeg.uuid,
      phoneNumber: @remoteLeg.cid_number,
    )

class Agent
  constructor: (@name) ->
    @calls = {}
    @callCount = 0
    @createDOM()
    store.agents[@name] = this

  createDOM: ->
    @dom = store.protoAgent.clone()
    @dom.attr('id', "agent-#{@name}")
    $('.name', @dom).text(@name)
    $('#agents').isotope('insert', @dom)

  setTimer: (@startingTime) ->
    $('.time-since-status-change', @dom).text(formatInterval(@startingTime))
    $('#agents').isotope('updateSortData', @dom)

    @timer = setInterval =>
      $('.time-since-status-change', @dom).text(formatInterval(@startingTime))
    , 1000

  fillFromAgent: (d) ->
    @setName(d.name)
    @setState(d.state)
    @setStatus(d.status)
    @setUsername(d.username)
    @setExtension(d.extension)

    @busy_delay_time = d.busy_delay_time
    @class_answered = d.class_answered
    @contact = d.contact

    @last_call_time = new Date(Date.parse(d.last_call_time))
    @last_bridge_end = new Date(Date.parse(d.last_bridge_end))
    @last_bridge_start = new Date(Date.parse(d.last_bridge_start))
    @last_offered_call = new Date(Date.parse(d.last_offered_call))
    @last_status_change = new Date(Date.parse(d.last_status_change))

    @max_no_answer = d.max_no_answer
    @no_answer_count = d.no_answer_count
    @ready_time = d.ready_time
    @reject_delay_time = d.reject_delay_time
    @system = d.system
    @talk_time = d.talk_time
    @type = d.type
    @uuid = d.uuid
    @wrap_up_time = d.wrap_up_time

    if @last_call_time
      @setTimer(@last_call_time)

    for call in d.calls
      msg = {
        call_created: call.call_created,
        left: {
          cid_number: call.caller_cid_num,
          cid_name: call.caller_cid_name,
          destination: call.caller_dest_num,
          channel: call.contact
          uuid: call.uuid,
        },
        right: {
          cid_number: call.callee_cid_num,
          cid_name: call.callee_cid_name,
          channel: call.contact,
          uuid: call.uuid,
        }
      }

      @got_call_start(msg)

  fillFromTier: (d) ->
    @setName(d.agent)
    @setState(d.state)
    @level = d.level
    @position = d.position
    @setQueue(d.queue)

  addCall: (call) ->
    @calls[call.uuid] = call
    @callCount += 1
    $('.more-calls', @dom).text('+') if @callCount > 1

  removeCall: (call) ->
    delete @calls[call.uuid]
    @callCount -= 1
    $('.more-calls', @dom).text('') if @callCount < 2

  got_call_start: (msg) ->
    extMatch = /(?:^|\/)(?:sip:)?(\d+)[@-]/
    [left, right] = [msg.left, msg.right]
    leftMatch = left.channel?.match?(extMatch)?[1]
    rightMatch = right.channel?.match?(extMatch)?[1]

    if @extension == leftMatch
      @makeCall(left, right, msg)
    else if @extension == rightMatch
      @makeCall(right, left, msg)
    else if right.destination == rightMatch
      @makeCall(right, left, msg)
    else if left.destination == leftMatch
      @makeCall(left, right, msg)
    else if left.cid_number == leftMatch
      @makeCall(left, right, msg)
    else if right.cid_number == rightMatch
      @makeCall(right, left, msg)

  makeCall: (left, right, msg) ->
    new Call(this, left, right, msg) unless @calls[left.uuid]

  got_channel_hangup: (msg) ->
    for key, value of msg
      if /unique|uuid/.test(key)
        if call = @calls[value]
          call.hangup(msg)
          return undefined

  got_status_change: (msg) ->
    @setStatus(msg.cc_agent_status)

  got_state_change: (msg) ->
    @setState(msg.cc_agent_state)

  setQueue: (@queue) ->
    $('.queue', @dom).text(@queue)
    @dom.addClass(queueToClass(queue))

  setName: (@name) ->
    @dom.attr('id', "agent-#{name}")

  setState: (@state) ->
    unless alias = store.stateMapping[state]
      return
    state = alias
    targetKlass = statusOrStateToClass("state-", state)
    for klass in @dom.attr('class').split(' ')
      @dom.removeClass(klass) if /^state-/.test(klass)
    @dom.addClass(targetKlass)
    $('.state', @dom).text(state)
    $('#agents').isotope('updateSortData', @dom)
    @syncDialogState()

  setStatus: (@status) ->
    targetKlass = statusOrStateToClass("status-", status)
    for klass in @dom.attr('class').split(' ')
      @dom.removeClass(klass) if /^status-/.test(klass)
    @dom.addClass(targetKlass)
    $('.status', @dom).text(status)
    $('#agents').isotope('updateSortData', @dom)
    @syncDialogStatus()

  setUsername: (@username) ->
    $('.username', @dom).text(@username)
    $('#agents').isotope('updateSortData', @dom)

  getUsername: ->
    $('.username', @dom).text()

  setExtension: (@extension) ->
    $('.extension', @dom).text(@extension)
    $('#agents').isotope('updateSortData', @dom)

  getExtension: ->
    $('.extension', @dom).text()

  calltap: ->
    p "Tapping #{@name} for #{store.agent}"
    store.ws.say(
      method: 'calltap',
      agent: @name,
      tapper: store.agent,
    )

  show: ->
    @dom.show()

  hide: ->
    @dom.hide()

  doubleClicked: ->
    @dialog = store.protoAgentDialog.clone(true)
    @dialog.attr('id', "dialog-#{@name}")
    @dialog.dialog(
      autoOpen: true,
      title: "#{@getExtension()} #{@getUsername()}",
      modal: false,
      width: 600,
      height: 400,
      open: (event, ui) =>
        @syncDialog()
        for uuid, call of @calls
          call.renderInDialog()

        $('.dialog-tabs .tab-title', @dialog).each (i,t) =>
          $(t).attr('href', "#dialog-tab-#{@name}-#{i}")
        $('.dialog-tabs .tab-content', @dialog).each (i,t) =>
          $(t).attr('id', "dialog-tab-#{@name}-#{i}")

        $('.dialog-tabs', @dialog).tabs(
          idPrefix: "dialog-tab-#{@name}",
          show: (showEvent, showUi) => @handleShowTab(showEvent, showUi),
        )

        $('.calltap', @dialog).click (event) =>
          @calltap()
          false
        $('.calls .calltap-uuid', @dialog).click (event) =>
          call = $(event.target).closest('.call')
          uuid = $('.uuid', call).text()
          realCall = @calls[uuid]
          realCall.calltap()
          false
        $('.status a', @dialog).click (event) =>
          store.ws.say(
            method: 'status_of',
            agent: @name,
            status: statusOrStateToClass('', $(event.target).text()).replace(/-/g, '_')
          )
          false
        $('.state a', @dialog).click (event) =>
          store.ws.say(
            method: 'state_of',
            agent: @name,
            state: $(event.target).attr('class'),
          )
          false
      close: (event, ui) =>
        @dialog.remove()
    )

  handleShowTab: (event, ui) ->
    href = $(ui.tab).attr('href')
    tab = $(href)

    if tab.hasClass('tab-status-log')
      store.ws.say(method: 'agent_status_history', agent: @name)
    else if tab.hasClass('tab-state-log')
      store.ws.say(method: 'agent_state_history', agent: @name)
    else if tab.hasClass('tab-call-log')
      store.ws.say(method: 'agent_call_history', agent: @name)

  got_agent_status_history: (msg) ->
    $('.tab-status-log tbody', @dialog).html('')
    for row in msg.history
      created_at = new Date(Date.parse(row.created_at))
      $('.tab-status-log tbody', @dialog).append(
        $('<tr>').html("<td>#{row.new_status}</td><td>#{created_at}</td>"))

  got_agent_state_history: (msg) ->
    $('.tab-state-log tbody', @dialog).html('')
    for row in msg.history
      created_at = new Date(Date.parse(row.created_at))
      $('.tab-state-log tbody', @dialog).append(
        $('<tr>').html("<td>#{row.new_state}</td><td>#{created_at}</td>"))

  got_agent_call_history: (msg) ->
    $('.tab-call-log tbody', @dialog).html('')
    for row in msg.history
      tr = $('<tr>', class: 'couch-link', couchid: row.couch_id)
      start = new Date(Date.parse(row.start_time))
      tr.append($('<td>').text(start.toLocaleTimeString()))
      tr.append($('<td>').text(formatPhoneNumber(row.caller_id_number)))
      tr.append($('<td>').text(formatPhoneNumber(row.caller_id_name)))
      tr.append($('<td>').text(formatPhoneNumber(row.destination_number)))
      tr.append($('<td>').text(row.context))
      tr.append($('<td>').text(row.duration))
      tr.append($('<td>').text(row.billsec))
      $('.tab-call-log tbody', @dialog).append(tr)

  syncDialog: ->
    @syncDialogStatus()
    @syncDialogState()

  syncDialogStatus: ->
    targetKlass = statusOrStateToClass("", @status)
    $(".status a", @dialog).removeClass('active')
    $(".status a.#{targetKlass}", @dialog).addClass('active')

  syncDialogState: ->
    targetKlass = @state
    $(".state a", @dialog).removeClass('active')
    $(".state a.#{targetKlass}", @dialog).addClass('active')

$ ->
  store.server = $('#server').text()
  store.server = "ws://" + location.hostname + ":8081/websocket" if store.server == ''
  store.agent = $('#agent_name').text()

  store.protoCall = $('#proto-call').detach()
  store.protoAgent = $('#proto-agent').detach()
  store.protoAgentDialog = $('#proto-agent-dialog').detach()

  $('#nav-queues a').live 'click', (event) =>
    queue = $(event.target).text()
    store.ws.say(method: 'agents_of', queue: queue)
    false

  $('#show-all-agents').live 'click', (event) ->
    $('#agents').isotope(filter: '*')
    false

  $('#search').keyup (event) =>
    if event.keyCode == 13
      event.preventDefault()

    raw = $(event.target).val()
    if query = searchToQuery(raw)
      $('#agents').isotope(filter: query)
    false

  $('#save-search').click (event) =>
    raw = $('#search').val()
    if query = searchToQuery(raw)
      unless store.searches[raw]
        store.searches[raw] = query
        $('#prev-search').append($('<option>', value: query).text(raw))

  $('#prev-search').change (event) =>
    query = $(event.target).val()
    $('#agents').isotope(filter: query)

  $('.sorter').click (event) ->
    sorter = $(event.target).attr('id').replace(/^sort-/, "")
    $('#agents').isotope(sortBy: sorter)
    false

  $('.agent').live 'dblclick', (event) =>
    agent_id = $(event.target).closest('.agent').attr('id').replace(/^agent-/, "")
    agent = store.agents[agent_id]
    agent.doubleClicked()
    false

  $('.couch-link').live 'dblclick', (event) =>
    uri_match = /^(https?:\/\/[^:]+:\d+\/)(\w+)/
    return unless $('#couch_uri').text().match(uri_match)
    tr = $(event.target).closest('tr')
    couchid = tr.attr('couchid')
    uri = $('#couch_uri').text().replace(uri_match, '$1_utils/document.html?$2/') + couchid
    window.open(uri, "Futon")

  $('#agents').isotope(
    itemSelector: '.agent',
    layoutMode: 'fitRows',
    getSortData: {
      username: (e) ->
        e.find('.username').text()
      extension: (e) ->
        e.find('.extension').text()
      status: (e) ->
        s = e.find('.status').text()
        order =
          switch s
            when 'Available'
              0.7
            when 'Available (On Demand)'
              0.8
            when 'On Break'
              0.9
            when 'Logged Out'
              1.0

        extension = e.find('.extension').text()
        parseFloat("" + order + extension)
      idle: (e) ->
        #$('#agents').isotope('updateSortData', $('#content'))
        [min, sec] = e.find('.time-since-status-change').text().split(':')
        (((parseInt(min, 10) * 60) + parseInt(sec, 10)) * -1)
    },
    sortBy: 'status',
  )

  store.ws = new Socket(new Controller())
  window.tcc_store = store # makes debugging sooo much easier :)
