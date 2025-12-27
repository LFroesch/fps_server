extends Node3D

@onready var server_status_label: Label3D = $ServerStatusLabel
@onready var connected_players_label: Label3D = $ConnectedPlayersLabel
@onready var server_version_label: Label3D = $ServerVersionLabel
@onready var port_label: Label3D = $PortLabel
@onready var address_label: Label3D = $AddressLabel

const ADDRESS := "127.0.0.1" # Address of where the server is running from / what the client needs to connect to
const VERSION := "v1.1.0" # Server Version Control / must match with client
# Figure a better way to display these always / or whatever
# Update on that UI when players connect / disconnect, lobbies start / end

func _ready() -> void:
	port_label.text = "Port: " + str(Server.PORT)
	address_label.text = "Address: " + str(ADDRESS)
	server_version_label.text = "Version:" + str(VERSION)
	connected_players_label.text = "Connected: " + str(Server.idle_clients.size())

func _process(delta: float) -> void:
	connected_players_label.text = "Connected: " + str(Server.idle_clients.size())
