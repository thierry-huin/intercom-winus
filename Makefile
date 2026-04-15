.PHONY: setup build up down logs clean

setup:
	mkdir -p backend/db frontend/js

build:
	docker-compose build

up:
	docker-compose up -d

down:
	docker-compose down

logs:
	docker-compose logs -f

clean:
	docker-compose down -v
	rm -f backend/db/intercom.db
