package main

import (
	"flag"
	"koding/db/mongodb"
	"koding/db/mongodb/modelhelper"
	"koding/kontrol/kontroldaemon/handler"
	"koding/kontrol/kontrolhelper"
	"koding/tools/config"
	"koding/tools/slog"
	"log"

	"github.com/streadway/amqp"
)

var (
	mongo         *mongodb.MongoDB
	configProfile = flag.String("c", "", "Configuration profile from file")
)

func init() {
	slog.SetPrefixName("kontrold")
	slog.Println(slog.SetOutputFile("/var/log/koding/kontroldaemon.log"))
}

func main() {
	flag.Parse()
	if *configProfile == "" {
		log.Fatal("Please define config file with -c")
	}

	conf := config.MustConfig(*configProfile)
	mongo = mongodb.NewMongoDB(conf.Mongo)
	modelhelper.Initialize(conf.Mongo)

	handler.Startup(conf)
	startRouting(conf)
}

func startRouting(conf *config.Config) {
	type bind struct {
		name     string
		queue    string
		key      string
		exchange string
		kind     string
	}

	streams := make(map[string]<-chan amqp.Delivery)
	bindings := []bind{
		bind{"api", "kontrol-api", "input.api", "infoExchange", "topic"},
		bind{"worker", "kontrol-worker", "input.worker", "workerExchange", "topic"},
		bind{"client", "kontrol-client", "", "clientExchange", "fanout"},
	}

	connection := kontrolhelper.CreateAmqpConnection(conf)
	channel := kontrolhelper.CreateChannel(connection)

	for _, b := range bindings {
		streams[b.name] = kontrolhelper.CreateStream(channel, b.kind, b.exchange, b.queue, b.key, true, false)
	}

	err := channel.Qos(len(bindings), 0, false)
	if err != nil {
		slog.Fatalf("basic.qos: %s", err)
	}

	slog.Println("started")
	for {
		select {
		case d := <-streams["api"]:
			go handler.ApiMessage(d.Body)
		case d := <-streams["worker"]:
			go handler.WorkerMessage(d.Body)
		case d := <-streams["client"]:
			go handler.ClientMessage(d)
		}
	}
}
