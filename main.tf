provider "google" {
  project = var.project
  region = "us-west1"
}

variable "project" {
  type = string
}

resource "google_compute_network" "redis_network" {
  name = "redis-network"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "redis_subnetwork" {
  name = "redis-subnetwork"
  ip_cidr_range = "10.0.0.0/24"
  region = "us-west1"
  network = google_compute_network.redis_network.id
}

resource "google_compute_address" "redis_static_address" {
  name = "redis-static-address"
  address_type = "INTERNAL" // internal static ip
  subnetwork = google_compute_subnetwork.redis_subnetwork.id
  region = "us-west1"
}

resource "google_compute_router" "redis_router" {
  name    = "redis-router"
  region  = google_compute_subnetwork.redis_subnetwork.region
  network = google_compute_network.redis_network.name

  bgp {
    asn = 64514
  }
}

resource "google_compute_router_nat" "redis_nat" {
  name                               = "redis-router-nat"
  router                             = google_compute_router.redis_router.name
  region                             = google_compute_router.redis_router.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

resource "google_compute_firewall" "allow_iap" {
  name = "allow-iap-redis"
  network = google_compute_network.redis_network.id
  allow {
    protocol = "tcp"
    ports = ["22", "3389"]
  }
  priority = 1000
  source_ranges = ["35.235.240.0/20"]
  target_tags = ["allow-iap-redis"]
}

resource "google_compute_instance_template" "redis_sentinel" {
  can_ip_forward = "false"
  disk {
    auto_delete  = "true"
    boot         = "true"
    device_name  = "redis-sentinel"
    disk_size_gb = "30"
    disk_type    = "pd-standard"
    mode         = "READ_WRITE"
    source_image = "ubuntu-os-cloud/ubuntu-2004-lts"
    # source_image = "projects/${var.project}/global/images/v2-ppd-cache-instance-2017-07-17-2"
    type         = "PERSISTENT"
  }
  machine_type = "t2d-standard-1"
  metadata = {
    serial-port-logging-enable = "TRUE"
    settings       = "main"
    startup-script = "#! /bin/bash\ncurl -fsSL https://packages.redis.io/gpg | sudo gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg\necho 'deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main' | sudo tee /etc/apt/sources.list.d/redis.list\nsudo apt-get update\nsudo apt-get install redis"
    type           = "sentinel"
  }
  # min_cpu_platform = "Automatic"
  name             = "redis-sentinel-group"
  network_interface {
    network = google_compute_network.redis_network.name
    subnetwork = google_compute_subnetwork.redis_subnetwork.name
  }

  scheduling {
    automatic_restart   = "true"
    min_node_cpus       = "0"
    on_host_maintenance = "MIGRATE"
    preemptible         = "false"
  }

  service_account {
    email  = "750756807971-compute@developer.gserviceaccount.com"
    # email  = var.service_account
    scopes = ["https://www.googleapis.com/auth/logging.write", "https://www.googleapis.com/auth/monitoring.write", "https://www.googleapis.com/auth/devstorage.read_only", "https://www.googleapis.com/auth/service.management.readonly", "https://www.googleapis.com/auth/source.read_only", "https://www.googleapis.com/auth/trace.append", "https://www.googleapis.com/auth/servicecontrol"]
  }

  tags = ["http-server", google_compute_firewall.allow_iap.name]
}

resource "google_compute_instance_from_template" "redis_sentinel_leader" {
  name = "redis-sentinel-leader"
  zone = "us-west1-b"
  source_instance_template = google_compute_instance_template.redis_sentinel.id
  network_interface {
    network = google_compute_network.redis_network.name
    subnetwork = google_compute_subnetwork.redis_subnetwork.name
    network_ip = google_compute_address.redis_static_address.address // set the reserved internal IP address for the instance
  }
}

resource "google_compute_instance_from_template" "redis_sentinel_worker" {
  name = "redis-sentinel-worker-1"
  zone = "us-west1-b"
  source_instance_template = google_compute_instance_template.redis_sentinel.id
  metadata = {
    startup-script = "echo 'leader ip: ${google_compute_address.redis_static_address.address}'"
  }

  # depends_on = [
  #   google_compute_instance_from_template.redis_sentinel_leader, // wait for the leader to be created
  # ]
}