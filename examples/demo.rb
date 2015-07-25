require 'sinatra'
require 'sinatra-websocket'
require 'pressure'

set :server, 'thin'
set :sockets, []

data = {}

Thread.new do
  loop do
    data = (0...8).map { (65 + rand(26)).chr }.join
    sleep(1.0 / 0.2)
  end
end

pressure = Pressure.new do
  data
end

pressure.wrapper_template = {
  someKey: 'Some Value',
  anotherKey: 'Another Value'
}

get '/' do
  if !request.websocket?
    erb :index
  else
    request.websocket do |ws|
      ws.onopen do
        pressure << ws
        puts "Connected: #{pressure.sockets.length}"
      end
      ws.onmessage do |msg|
        EM.next_tick { pressure.sockets.each { |socket| socket.send(msg) } }
      end
      ws.onclose do
        warn('websocket closed')
        pressure.delete ws
      end
    end
  end
end

__END__
@@ index
<html>
  <body>
     <h1>Pressure Demo</h1>
     <form id="form">
       <input type="text" id="input" value="send a message"></input>
     </form>
     <div id="msgs"></div>
  </body>

  <script type="text/javascript">
    window.onload = function(){
      (function(){
        var show = function(el){
          return function(msg){ el.innerHTML = msg + '<br />' + el.innerHTML; }
        }(document.getElementById('msgs'));

        var ws       = new WebSocket('ws://' + window.location.host + window.location.pathname);
        ws.onopen    = function()  { show('websocket opened'); };
        ws.onclose   = function()  { show('websocket closed'); }
        ws.onmessage = function(m) { show('websocket message: ' +  m.data); };

        var sender = function(f){
          var input     = document.getElementById('input');
          input.onclick = function(){ input.value = "" };
          f.onsubmit    = function(){
            ws.send(input.value);
            input.value = "";
            return false;
          }
        }(document.getElementById('form'));
      })();
    }
  </script>
</html>
