import requests

url = "http://0.0.0.0:3000/api/jobs"  # change to your endpoint

# Rails-style nested params
data = {
    "api_token": "544d6e7d663774b9e243a52e5ef7a718",
    "endpoint_name": "Geocode",
    "options[name1]": "value1",
    "options[name2]": "value2",
    "options[name3]": "value3",
    "input_data_content_type": "text/csv",
    "output_data_content_type": "text/csv"
}

# File upload
files = {
    "input_data_file": open("example.csv", "rb")  # change to your file path
}

response = requests.post(url, data=data, files=files)

print("Status Code:", response.status_code)
print("Response Body:", response.text)