Instance under ecs cluster: ECS Cluster Name: otel-sample-apps
i-0c09824da8b1c165f
i-0f146b4d8449d639d
i-0ffd2ea7e79dc6174

ASG: otel-opensource-asg
sg-07d2a5d42ac97171c

VPC ID: vpc-0018aa4902fa67a2c
Subnet ID: subnet-0548c87344ac6f8a2
Application Cluster:
ECS Cluster ARN: arn:aws:ecs:us-east-1:584554046133/otel-sample-apps
ECS Cluster Name: otel-sample-apps

HTTP: http://otel-gateway-nlb-3b88104205cc8ef6.elb.us-east-1.amazonaws.com:4318
gRPC: otel-gateway-nlb-3b88104205cc8ef6.elb.us-east-1.amazonaws.com:4317

grafana-stack-lgtm.pem

git add . && git commit -m "First change" && git push origin master

chmod +x ./scripts/05-validate.sh