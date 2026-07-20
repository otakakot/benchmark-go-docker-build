package main

import (
	"net/http"

	"github.com/gin-gonic/gin"
	"go.uber.org/zap"
)

func main() {
	logger, err := zap.NewProduction()
	if err != nil {
		panic(err)
	}
	defer logger.Sync()

	engine := gin.Default()

	engine.GET("/health", func(ctx *gin.Context) {
		logger.Info("handling request", zap.String("path", "/health"))

		ctx.JSON(http.StatusOK, "ok")
	})

	if err := engine.Run(); err != nil {
		panic(err)
	}
}
