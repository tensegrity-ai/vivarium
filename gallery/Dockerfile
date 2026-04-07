FROM golang:1.22-alpine AS build
WORKDIR /app
COPY go.mod main.go ./
RUN go build -o gallery .

FROM alpine:3.19
COPY --from=build /app/gallery /usr/local/bin/gallery
RUN mkdir -p /srv/public
CMD ["gallery"]
