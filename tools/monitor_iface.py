import os
import time
import csv
import argparse
import pandas as pd
import matplotlib.pyplot as plt

def monitor_iface(interface, csv_path):

    # Create the CSV file with header row
    with open(csv_path, 'w', newline='') as csvfile:
        writer = csv.writer(csvfile)
        writer.writerow(['timestamp', 'rx_bytes', 'tx_bytes'])

    # Continuously read and write interface stats to CSV file
    while True:
        # Check if interface exists
        if not os.path.exists(f'/sys/class/net/{interface}'):
            print(f"Interface {interface} does not exist. Exiting...")
            break

        # Read rx_bytes and tx_bytes from interface file
        with open(f'/sys/class/net/{interface}/statistics/rx_bytes', 'r') as rx_file, \
             open(f'/sys/class/net/{interface}/statistics/tx_bytes', 'r') as tx_file:
            rx_bytes = int(rx_file.read())
            tx_bytes = int(tx_file.read())

        # Write stats to CSV file with current timestamp
        with open(csv_path, 'a', newline='') as csvfile:
            writer = csv.writer(csvfile)
            writer.writerow([time.time(), rx_bytes, tx_bytes])

        # Sleep for one second
        time.sleep(1)

def plot_csv(csv_path):
    # Load CSV file into pandas DataFrame
    df = pd.read_csv(csv_path)

    # Convert timestamp column to datetime
    df['timestamp'] = pd.to_datetime(df['timestamp'], unit='s')

    #Convert rx_bytes and tx_bytes to MB
    df['rx_bytes'] = df['rx_bytes'] / 1e6
    df['tx_bytes'] = df['tx_bytes'] / 1e6

    # Plot rx_bytes and tx_bytes over time
    fig, ax = plt.subplots()
    ax.plot(df['timestamp'], df['rx_bytes'], label='rx_bytes')
    ax.plot(df['timestamp'], df['tx_bytes'], label='tx_bytes')
    ax.set_xlabel('Time')
    ax.set_ylabel('MBytes')
    ax.legend()

    # Save plot with timestamp in filename
    timestamp = pd.Timestamp.now().strftime('%Y%m%d_%H%M%S')
    plot_path = f'{csv_path}_{timestamp}.png'
    plt.savefig(plot_path)

    # Rename CSV file with timestamp
    new_csv_path = csv_path.split('.csv')[0]
    os.rename(csv_path, f'{new_csv_path}_{timestamp}.csv')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Monitor network interface')
    parser.add_argument('interface', type=str, help='Name of the network interface to monitor')
    parser.add_argument('csv_path', type=str, help='Path to the CSV file to write stats to')
    args = parser.parse_args()

    monitor_iface(args.interface, args.csv_path)
    plot_csv(args.csv_path)
