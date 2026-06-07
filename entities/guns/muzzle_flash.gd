class_name MuzzleFlash
extends Node2D

@onready var core_flash = $CoreFlash
@onready var bloom_flash = $BloomFlash

func flash() -> void:
	core_flash.emitting = true
	bloom_flash.emitting = true