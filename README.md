# aws-ecs-route53-presence

Registers and unregisters a container IP address with Route53 to support round-robin distribution of work loads to ECS containers.

One use case is Consul. Consul provides service discovery, but the Consul servers must be found by the clients. This container can be included in the ECS task definition with the Consul server and register the IP address with a private hosted zone. Consul agents can reference the hosted zone to get to the servers.

The container supports selecting an IP address that matches a CIDR block, either IPv4 or IPv6. A Fargate container may have several IP address and the CIDR block filtering supports choosing the desired address.

## Configuration

- `HOSTED_ZONE_ID` (required) The ID of the hosted zone, this can be found in the Route53 console.
- `DNS_NAME` (required) The short name (i.e. without the hosted zone name) for registration. For example, `consul` or `consul-stage`.
- `TTL` (optional) The TTL in seconds for the registration, defaults to 300.
- `ADDRESS_CIDR` (optional but recommended) IPv4 CIDR block from which to choose an IP address, the default is `0.0.0.0/0`, which is any of them.
- `ADDRESS_CIDR6` (optional but recommended) IPv6 CIDR block from which to choose an IP address, the default is `0.0.0.0/0`, which is any of them.

The `ADDRESS_CIDR` and `ADDRESS_CIDR6` values use [grepcidr](https://github.com/frohoff/grepcidr.git) to determine if an address matches. Any format supported by `grepcidr` can be used in these variables.

## Credentials

The AWS CLI is used to communicate with Route53. Authentication methods supported by the CLI are supported by this container. It is recommended to assign a role to the task that has permissions to read and write the hosted zone.

The container exposes `/root/.aws` as a volume. A `.aws` directory with credentials may be mounted to this volume to use those credentials. The `AWS_PROFILE` environment variable can be set to use a specific profile.

## Lifecycle

The container registers with Route53 on start. It waits until a termination signal is received and then unregisters with Route53.

It's possible for an IP address to not be unregistered, in case a TERM signal is sent to the container, or it otherwise isn't cleanly stopped. The only way to unregister the address is to remove it from the Route53 console or via other means.

It's possible for an IP address to not be registered when it should. Starting multiple containers concurrently may introduce a race condition where one container's registration overwrites another.
