terraform {
  backend "gcs" {
    bucket  = "tt-tfstate"  # Replace with your bucket name
    prefix  = "facesheets"  # Example prefix
  }
}

variable "project_id" {
  type = string
  description = "The ID of the Google Cloud project"
  default = "proj-01j0kth75fkhc" 
}

variable "region" {
  type = string
  default = "us-central1" 
}

resource "random_id" "name_suffix" {
  byte_length = 3
}

resource "google_project_service" "artifact_registry_api" {
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
  project            = var.project_id
}

resource "google_project_service" "run_api" {
  service            = "run.googleapis.com"
  disable_on_destroy = false
  project            = var.project_id
}

resource "google_project_service" "iam_api" {
  service            = "iam.googleapis.com"
  disable_on_destroy = false
  project            = var.project_id
}

resource "google_project_service" "storage_api" {
  service            = "storage.googleapis.com"
  disable_on_destroy = false
  project            = var.project_id
}

resource "google_project_service" "secretmanager_api" {
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
  project            = var.project_id
}

# Create a service account
resource "google_service_account" "facesheets_sa" {
  account_id   = "tt-facesheets-${random_id.name_suffix.hex}"
  display_name = "Facesheets Service Account"
  project      = var.project_id
}
 
# Assign roles to the service account
resource "google_project_iam_member" "facesheets_cloud_run_invoker" {
  project = var.project_id
  role    = "roles/run.invoker"
  member  = "serviceAccount:${google_service_account.facesheets_sa.email}"
}
 
resource "google_project_iam_member" "facesheets_eventarc_event_receiver" {
  project = var.project_id
#  role    = "roles/eventarc.eventReceiver"
  role    = "roles/eventarc.admin"
  member  = "serviceAccount:${google_service_account.facesheets_sa.email}"
}
 
resource "google_project_iam_member" "facesheets_storage_object_admin" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.facesheets_sa.email}"
}

resource "google_project_iam_member" "facesheets_artifact_registry_create_on_push_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.createOnPushWriter"
  member  = "serviceAccount:${google_service_account.facesheets_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "service_account_access" {
  secret_id = "projects/${var.project_id}/secrets/tt-facesheets-bucket-name"
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.facesheets_sa.email}"
}

resource "google_cloud_run_v2_service" "default" {
  name     = "tt-facesheets-${random_id.name_suffix.hex}"
  location = var.region 
  project  = var.project_id
  deletion_protection = false

  template {
    containers {
      image = "gcr.io/cloudrun/hello:latest"
    }
  }

  depends_on = [google_project_service.run_api]
}

# Retrieve the bucket name from the Secret Manager secret
data "google_secret_manager_secret_version" "bucket_name" {
  secret = "projects/${var.project_id}/secrets/tt-facesheets-bucket-name"
}

resource "google_eventarc_trigger" "storage_to_cloud_run" {
  name     = "tt-storage-to-cloud-run-trigger-${random_id.name_suffix.hex}"
  location = var.region
  project  = var.project_id

  matching_criteria {
    attribute = "type"
    value     = "google.cloud.storage.object.v1.finalized"
  }
  matching_criteria {
    attribute = "bucket"
    value     = data.google_secret_manager_secret_version.bucket_name.secret_data
  }

  destination {
    cloud_run_service {
      service = google_cloud_run_v2_service.default.name
      region  = var.region
    }
  }

  # Use the service account you created for facesheets
  service_account = google_service_account.facesheets_sa.email
}
