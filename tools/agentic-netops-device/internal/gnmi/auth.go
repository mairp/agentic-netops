package gnmi

import (
	"context"
	"strings"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

// gnmic sends credentials as gRPC metadata keys "username" and "password"
// (openconfig/gnmic pkg/api/target/target.go). The interceptor enforces the
// lab credentials on every RPC.
func checkAuth(ctx context.Context, user, pass string) error {
	md, ok := metadata.FromIncomingContext(ctx)
	if !ok {
		return status.Error(codes.Unauthenticated, "missing metadata")
	}
	u := md.Get("username")
	p := md.Get("password")
	if len(u) == 0 || len(p) == 0 {
		return status.Error(codes.Unauthenticated, "missing username/password")
	}
	if strings.TrimSpace(u[0]) != user || strings.TrimSpace(p[0]) != pass {
		return status.Error(codes.Unauthenticated, "invalid credentials")
	}
	return nil
}

func authUnaryInterceptor(user, pass string) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		if err := checkAuth(ctx, user, pass); err != nil {
			return nil, err
		}
		return handler(ctx, req)
	}
}

func authStreamInterceptor(user, pass string) grpc.StreamServerInterceptor {
	return func(srv any, ss grpc.ServerStream, info *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
		if err := checkAuth(ss.Context(), user, pass); err != nil {
			return err
		}
		return handler(srv, ss)
	}
}
